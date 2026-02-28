#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_ENV="${BOOTSTRAP_ENV:-/opt/openclaw/bootstrap.env}"

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

  : "${ADMIN_USER:=root}"
  : "${OPENCLAW_OFFICIAL_HOME_DIR:=/opt/openclaw/.openclaw}"
  : "${OPENCLAW_MAIN_CONFIG_JSON:=${OPENCLAW_OFFICIAL_HOME_DIR}/openclaw.json}"
  : "${OPENCLAW_WORKSPACE_DIR:=${OPENCLAW_OFFICIAL_HOME_DIR}/workspace}"
  : "${OPENCLAW_SKILLS_DIR:=${OPENCLAW_OFFICIAL_HOME_DIR}/skills}"
  : "${OPENCLAW_TOOLS_DIR:=${OPENCLAW_OFFICIAL_HOME_DIR}/tools}"
  : "${OPENCLAW_PERSONALIZATION_DIR:=${REPO_ROOT}/templates/openclaw-personalization}"
  : "${OPENCLAW_PERSONALIZATION_OVERWRITE:=1}"
  OPENCLAW_IMPORT_PERSONALIZATION=1
}

# shellcheck source=../ubuntu/lib/openclaw_runtime.sh
source "${REPO_ROOT}/scripts/ubuntu/lib/openclaw_runtime.sh"

main(){
  need_root
  load_env

  init_openclaw_runtime_layout
  import_openclaw_personalization

  log "Done. Personalization import finished."
}

main "$@"
