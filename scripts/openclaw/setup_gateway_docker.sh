#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_ENV="${BOOTSTRAP_ENV:-/opt/openclaw/bootstrap.env}"

die(){ echo -e "\n[x] $*\n" >&2; exit 1; }
log(){ echo -e "\n[+] $*\n"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run with sudo/root"; }

load_env(){
  local inherited_openclaw_mem_limit="${OPENCLAW_MEM_LIMIT:-}"
  local inherited_openclaw_cpu_quota="${OPENCLAW_CPU_QUOTA:-}"
  local inherited_openclaw_cpu_shares="${OPENCLAW_CPU_SHARES:-}"

  [[ -f "$BOOTSTRAP_ENV" ]] || die "Could not find $BOOTSTRAP_ENV"
  set -a
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_ENV"
  set +a

  [[ -n "$inherited_openclaw_mem_limit" ]] && OPENCLAW_MEM_LIMIT="$inherited_openclaw_mem_limit"
  [[ -n "$inherited_openclaw_cpu_quota" ]] && OPENCLAW_CPU_QUOTA="$inherited_openclaw_cpu_quota"
  [[ -n "$inherited_openclaw_cpu_shares" ]] && OPENCLAW_CPU_SHARES="$inherited_openclaw_cpu_shares"

  : "${OPENCLAW_REPO_URL:=https://github.com/openclaw/openclaw.git}"
  : "${OPENCLAW_REPO_REF:=main}"
  : "${OPENCLAW_GATEWAY_DIR:=/opt/openclaw/gateway}"
  : "${OPENCLAW_SHARED_NETWORK:=openclaw-shared}"
  : "${OPENCLAW_AUTOWIRE_INFRA:=1}"
  : "${OPENCLAW_OFFICIAL_HOME_DIR:=/opt/openclaw/.openclaw}"
  : "${OPENCLAW_MAIN_CONFIG_JSON:=${OPENCLAW_OFFICIAL_HOME_DIR}/openclaw.json}"
  : "${OPENCLAW_WORKSPACE_DIR:=${OPENCLAW_OFFICIAL_HOME_DIR}/workspace}"
  : "${OPENCLAW_SKILLS_DIR:=${OPENCLAW_OFFICIAL_HOME_DIR}/skills}"
  : "${OPENCLAW_TOOLS_DIR:=${OPENCLAW_OFFICIAL_HOME_DIR}/tools}"
  : "${OPENCLAW_AUTOWIRE_RUNTIME:=1}"
  : "${OPENCLAW_DOCKER_APT_PACKAGES:=}"
  : "${OPENCLAW_EXTRA_MOUNTS:=}"
  : "${OPENCLAW_HOME_VOLUME:=}"
  : "${OPENCLAW_MEM_LIMIT:=1536m}"
  : "${OPENCLAW_CPU_QUOTA:=1.50}"
  : "${OPENCLAW_CPU_SHARES:=2048}"

  : "${POSTGRES_DB:=openclaw}"
  : "${POSTGRES_USER:=openclaw}"
  : "${POSTGRES_PASSWORD:=CHANGE_ME_STRONG}"
  : "${OPENCLAW_POSTGRES_HOST:=postgres}"
  : "${OPENCLAW_POSTGRES_PORT:=5432}"
  : "${OPENCLAW_REDIS_HOST:=valkey}"
  : "${OPENCLAW_REDIS_PORT:=6379}"
  : "${OPENCLAW_POSTGRES_URL:=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${OPENCLAW_POSTGRES_HOST}:${OPENCLAW_POSTGRES_PORT}/${POSTGRES_DB}}"
  : "${OPENCLAW_REDIS_URL:=redis://${OPENCLAW_REDIS_HOST}:${OPENCLAW_REDIS_PORT}/0}"
}

ensure_shared_network(){
  docker network inspect "${OPENCLAW_SHARED_NETWORK}" >/dev/null 2>&1 || docker network create "${OPENCLAW_SHARED_NETWORK}" >/dev/null
}

clone_or_update_repo(){
  if [[ -d "$OPENCLAW_GATEWAY_DIR/.git" ]]; then
    log "Updating OpenClaw repo in $OPENCLAW_GATEWAY_DIR"
    git -C "$OPENCLAW_GATEWAY_DIR" fetch --all --tags
  else
    log "Cloning OpenClaw repo into $OPENCLAW_GATEWAY_DIR"
    install -d -m 755 "$(dirname "$OPENCLAW_GATEWAY_DIR")"
    git clone "$OPENCLAW_REPO_URL" "$OPENCLAW_GATEWAY_DIR"
  fi

  git -C "$OPENCLAW_GATEWAY_DIR" checkout "$OPENCLAW_REPO_REF"
}

run_official_setup(){
  local setup_script="$OPENCLAW_GATEWAY_DIR/docker-setup.sh"
  [[ -f "$setup_script" ]] || die "Missing docker-setup.sh in $OPENCLAW_GATEWAY_DIR"
  [[ -x "$setup_script" ]] || chmod +x "$setup_script"

  log "Running official docker-setup.sh (interactive onboarding)"
  (
    cd "$OPENCLAW_GATEWAY_DIR"
    OPENCLAW_DOCKER_APT_PACKAGES="$OPENCLAW_DOCKER_APT_PACKAGES" \
    OPENCLAW_EXTRA_MOUNTS="$OPENCLAW_EXTRA_MOUNTS" \
    OPENCLAW_HOME_VOLUME="$OPENCLAW_HOME_VOLUME" \
    ./docker-setup.sh
  )
}

write_resource_override(){
  local override_file="$OPENCLAW_GATEWAY_DIR/docker-compose.resource.override.yml"
  log "Writing resource override: $override_file"

  cat > "$override_file" <<CFG
services:
  openclaw-gateway:
    mem_limit: ${OPENCLAW_MEM_LIMIT}
    cpus: ${OPENCLAW_CPU_QUOTA}
    cpu_shares: ${OPENCLAW_CPU_SHARES}
CFG
}

write_infra_autowire_override(){
  local override_file="$OPENCLAW_GATEWAY_DIR/docker-compose.infra.override.yml"
  [[ "${OPENCLAW_AUTOWIRE_INFRA}" == "1" ]] || return 0

  log "Writing infra autowire override: $override_file"
  cat > "$override_file" <<CFG
services:
  openclaw-gateway:
    networks:
      - default
      - openclaw_shared
    environment:
      - DATABASE_URL=${OPENCLAW_POSTGRES_URL}
      - POSTGRES_URL=${OPENCLAW_POSTGRES_URL}
      - POSTGRES_DSN=${OPENCLAW_POSTGRES_URL}
      - PGHOST=${OPENCLAW_POSTGRES_HOST}
      - PGPORT=${OPENCLAW_POSTGRES_PORT}
      - PGDATABASE=${POSTGRES_DB}
      - PGUSER=${POSTGRES_USER}
      - PGPASSWORD=${POSTGRES_PASSWORD}
      - REDIS_URL=${OPENCLAW_REDIS_URL}
      - VALKEY_URL=${OPENCLAW_REDIS_URL}
      - CACHE_URL=${OPENCLAW_REDIS_URL}
networks:
  openclaw_shared:
    external: true
    name: ${OPENCLAW_SHARED_NETWORK}
CFG
}

write_runtime_autowire_override(){
  local override_file="$OPENCLAW_GATEWAY_DIR/docker-compose.runtime.override.yml"
  [[ "${OPENCLAW_AUTOWIRE_RUNTIME}" == "1" ]] || return 0

  log "Writing runtime autowire override: $override_file"
  cat > "$override_file" <<CFG
services:
  openclaw-gateway:
    volumes:
      - ${OPENCLAW_OFFICIAL_HOME_DIR}:/root/.openclaw
    environment:
      - OPENCLAW_BOOTSTRAP_CONFIG=/root/.openclaw/openclaw.json
      - OPENCLAW_WORKSPACE_DIR=/root/.openclaw/workspace
      - OPENCLAW_SKILLS_DIR=/root/.openclaw/skills
      - OPENCLAW_TOOLS_DIR=/root/.openclaw/tools
CFG
}

start_gateway(){
  log "Starting openclaw-gateway with resource override"
  (
    cd "$OPENCLAW_GATEWAY_DIR"
    if [[ "${OPENCLAW_AUTOWIRE_INFRA}" == "1" ]]; then
      if [[ "${OPENCLAW_AUTOWIRE_RUNTIME}" == "1" ]]; then
        docker compose \
        -f docker-compose.yml \
        -f docker-compose.resource.override.yml \
        -f docker-compose.infra.override.yml \
        -f docker-compose.runtime.override.yml \
        up -d openclaw-gateway
      else
        docker compose \
        -f docker-compose.yml \
        -f docker-compose.resource.override.yml \
        -f docker-compose.infra.override.yml \
        up -d openclaw-gateway
      fi
    else
      if [[ "${OPENCLAW_AUTOWIRE_RUNTIME}" == "1" ]]; then
        docker compose \
        -f docker-compose.yml \
        -f docker-compose.resource.override.yml \
        -f docker-compose.runtime.override.yml \
        up -d openclaw-gateway
      else
        docker compose \
        -f docker-compose.yml \
        -f docker-compose.resource.override.yml \
        up -d openclaw-gateway
      fi
    fi
  )
}

print_hints(){
  cat <<MSG
OpenClaw Gateway setup complete.
Dashboard (default): http://127.0.0.1:18789
Get dashboard token:
  cd ${OPENCLAW_GATEWAY_DIR}
  docker compose run --rm openclaw-cli dashboard --no-open
MSG
}

main(){
  need_root
  load_env
  ensure_shared_network
  clone_or_update_repo
  run_official_setup
  write_resource_override
  write_infra_autowire_override
  write_runtime_autowire_override
  start_gateway
  print_hints
}

main "$@"
