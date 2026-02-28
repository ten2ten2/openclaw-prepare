#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_ENV="${BOOTSTRAP_ENV:-/opt/openclaw/bootstrap.env}"
START_INFRA="${START_INFRA:-1}"

log(){ echo -e "\n[+] $*\n"; }
warn(){ echo -e "\n[!] $*\n" >&2; }
die(){ echo -e "\n[x] $*\n" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run with sudo/root"; }

load_env(){
  [[ -f "$BOOTSTRAP_ENV" ]] || die "Could not find $BOOTSTRAP_ENV (copy from templates/bootstrap.env.example and fill in values)"

  set -a
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_ENV"
  set +a

  : "${ADMIN_USER:?ADMIN_USER is not set}"
  : "${TIMEZONE:=America/Los_Angeles}"
  : "${HOSTNAME_FQDN:=openclaw-1}"
  : "${SSH_PORT:=22}"
  : "${OPENCLAW_BASE:=/opt/openclaw}"
  : "${SSH_PUBKEY:=}"

  : "${POSTGRES_DB:=openclaw}"
  : "${POSTGRES_USER:=openclaw}"
  : "${POSTGRES_PASSWORD:=CHANGE_ME_STRONG}"
  : "${PGVECTOR_IMAGE:=pgvector/pgvector:pg18-trixie}"
  : "${VALKEY_IMAGE:=valkey/valkey:9}"

  : "${PREFLIGHT_STRICT:=1}"
  : "${ALLOW_WEAK_HOST:=0}"
  : "${MIN_RAM_GB:=4}"
  : "${MIN_CPU_CORES:=2}"
  : "${MIN_DISK_FREE_GB:=80}"
  : "${FORCE_RAM_TIER:=}"

  : "${OPENCLAW_ENABLE_DOCKER_GATEWAY:=1}"
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
  : "${OPENCLAW_AGENT_TARGET:=10}"
  : "${OPENCLAW_WORKER_PER_AGENTS:=2}"
  : "${OPENCLAW_DOCKER_APT_PACKAGES:=}"
  : "${OPENCLAW_EXTRA_MOUNTS:=}"
  : "${OPENCLAW_HOME_VOLUME:=}"
  : "${ENABLE_ZRAM:=1}"
  : "${ENABLE_SWAPFILE:=1}"
}

# shellcheck source=./lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=./lib/tuning.sh
source "${SCRIPT_DIR}/lib/tuning.sh"
# shellcheck source=./lib/budget.sh
source "${SCRIPT_DIR}/lib/budget.sh"
# shellcheck source=./lib/system.sh
source "${SCRIPT_DIR}/lib/system.sh"
# shellcheck source=./lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=./lib/cloudflared.sh
source "${SCRIPT_DIR}/lib/cloudflared.sh"
# shellcheck source=./lib/infra.sh
source "${SCRIPT_DIR}/lib/infra.sh"
# shellcheck source=./lib/openclaw_runtime.sh
source "${SCRIPT_DIR}/lib/openclaw_runtime.sh"

print_summary(){
  cat <<SUM
==================== Summary ====================
Host checks:
  OS: Ubuntu ${OS_VERSION}
  RAM: ${RAM_GB} GiB | CPU: ${CPU_CORES} cores | Disk Free: ${DISK_FREE_GB} GiB
  RAM Tier: ${RAM_TIER}

Runtime Budgets:
  OS_RESERVE_GB=${OS_RESERVE_GB}
  OPENCLAW_MEM_GB=${OPENCLAW_MEM_GB}
  POSTGRES_MEM_GB=${POSTGRES_MEM_GB}
  REDIS_MEM_GB=${REDIS_MEM_GB}
  OPENCLAW_MEM_LIMIT=${OPENCLAW_MEM_LIMIT}
  POSTGRES_MEM_LIMIT=${POSTGRES_MEM_LIMIT}
  VALKEY_MEM_LIMIT=${VALKEY_MEM_LIMIT}

CPU Allocation:
  OPENCLAW_CPU_QUOTA=${OPENCLAW_CPU_QUOTA} | OPENCLAW_CPU_SHARES=${OPENCLAW_CPU_SHARES}
  POSTGRES_CPU_QUOTA=${POSTGRES_CPU_QUOTA} | POSTGRES_CPU_SHARES=${POSTGRES_CPU_SHARES}
  REDIS_CPU_QUOTA=${REDIS_CPU_QUOTA} | REDIS_CPU_SHARES=${REDIS_CPU_SHARES}

OpenClaw:
  OPENCLAW_AGENT_TARGET=${OPENCLAW_AGENT_TARGET}
  OPENCLAW_WORKER_PER_AGENTS=${OPENCLAW_WORKER_PER_AGENTS}
  OPENCLAW_WORKERS_RECOMMENDED=${OPENCLAW_WORKERS_RECOMMENDED}
  OPENCLAW_OFFICIAL_HOME_DIR=${OPENCLAW_OFFICIAL_HOME_DIR}
  OPENCLAW_WORKSPACE_DIR=${OPENCLAW_WORKSPACE_DIR}
  OPENCLAW_SKILLS_DIR=${OPENCLAW_SKILLS_DIR}
  OPENCLAW_TOOLS_DIR=${OPENCLAW_TOOLS_DIR}
  OPENCLAW_MAIN_CONFIG_JSON=${OPENCLAW_MAIN_CONFIG_JSON}

Postgres Applied:
  PG_MAX_WORKER_PROCESSES=${PG_MAX_WORKER_PROCESSES}
  PG_MAX_PARALLEL_WORKERS=${PG_MAX_PARALLEL_WORKERS}
  PG_MAX_PARALLEL_WORKERS_PER_GATHER=${PG_MAX_PARALLEL_WORKERS_PER_GATHER}
  PG_MAX_PARALLEL_MAINTENANCE_WORKERS=${PG_MAX_PARALLEL_MAINTENANCE_WORKERS}
  SWAP_GB=${SWAP_GB}
  POSTGRES_SHM_SIZE=${POSTGRES_SHM_SIZE}
  VALKEY_MAXMEM=${VALKEY_MAXMEM}
  PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS}
  PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE}
  PG_WORK_MEM=${PG_WORK_MEM}
  PG_MAINTENANCE_WORK_MEM=${PG_MAINTENANCE_WORK_MEM}
  PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS}
=================================================
SUM
}

main(){
  need_root
  load_env

  run_preflight
  mark_user_overrides
  apply_ram_tier_defaults
  apply_dynamic_budget

  apt_basics
  set_identity
  create_admin
  ssh_hardening
  firewall
  fail2ban_cfg
  unattended_upgrades

  swap_and_sysctl
  disable_thp
  raise_limits

  install_docker_latest
  install_cloudflared_latest

  render_infra
  ensure_shared_network
  maybe_start_infra
  OPENCLAW_AUTOWIRE_INFRA_JSON=$([[ "${OPENCLAW_AUTOWIRE_INFRA}" == "1" ]] && echo true || echo false)
  OPENCLAW_AUTOWIRE_RUNTIME_JSON=$([[ "${OPENCLAW_AUTOWIRE_RUNTIME}" == "1" ]] && echo true || echo false)
  init_openclaw_runtime_layout
  write_openclaw_bootstrap_json

  if [[ "${OPENCLAW_ENABLE_DOCKER_GATEWAY}" == "1" ]]; then
    OPENCLAW_MEM_LIMIT="${OPENCLAW_MEM_LIMIT}" \
    OPENCLAW_CPU_QUOTA="${OPENCLAW_CPU_QUOTA}" \
    OPENCLAW_CPU_SHARES="${OPENCLAW_CPU_SHARES}" \
    OPENCLAW_GATEWAY_DIR="${OPENCLAW_GATEWAY_DIR}" \
    OPENCLAW_REPO_URL="${OPENCLAW_REPO_URL}" \
    OPENCLAW_REPO_REF="${OPENCLAW_REPO_REF}" \
    OPENCLAW_SHARED_NETWORK="${OPENCLAW_SHARED_NETWORK}" \
    OPENCLAW_AUTOWIRE_INFRA="${OPENCLAW_AUTOWIRE_INFRA}" \
    OPENCLAW_OFFICIAL_HOME_DIR="${OPENCLAW_OFFICIAL_HOME_DIR}" \
    OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR}" \
    OPENCLAW_SKILLS_DIR="${OPENCLAW_SKILLS_DIR}" \
    OPENCLAW_TOOLS_DIR="${OPENCLAW_TOOLS_DIR}" \
    OPENCLAW_MAIN_CONFIG_JSON="${OPENCLAW_MAIN_CONFIG_JSON}" \
    OPENCLAW_AUTOWIRE_RUNTIME="${OPENCLAW_AUTOWIRE_RUNTIME}" \
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES}" \
    OPENCLAW_EXTRA_MOUNTS="${OPENCLAW_EXTRA_MOUNTS}" \
    OPENCLAW_HOME_VOLUME="${OPENCLAW_HOME_VOLUME}" \
    BOOTSTRAP_ENV="${BOOTSTRAP_ENV}" \
    bash "${REPO_ROOT}/scripts/openclaw/setup_gateway_docker.sh"
  fi

  print_summary

  log "Done. Next step: sudo bash scripts/cloudflare/setup_tunnel.sh"
}

main "$@"
