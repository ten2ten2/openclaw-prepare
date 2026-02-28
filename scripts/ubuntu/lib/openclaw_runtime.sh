#!/usr/bin/env bash

init_openclaw_runtime_layout(){
  local owner_group="root:root"

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    owner_group="${ADMIN_USER}:${ADMIN_USER}"
  fi

  install -d -m 0750 "${OPENCLAW_OFFICIAL_HOME_DIR}" \
    "${OPENCLAW_WORKSPACE_DIR}" \
    "${OPENCLAW_SKILLS_DIR}" \
    "${OPENCLAW_TOOLS_DIR}"

  chown -R "${owner_group}" "${OPENCLAW_OFFICIAL_HOME_DIR}"
}

import_openclaw_personalization(){
  local src_dir="${OPENCLAW_PERSONALIZATION_DIR}"
  local overwrite="${OPENCLAW_PERSONALIZATION_OVERWRITE:-1}"
  local owner_group="root:root"

  [[ "${OPENCLAW_IMPORT_PERSONALIZATION}" == "1" ]] || return 0

  if [[ ! -d "${src_dir}" ]]; then
    warn "Personalization directory not found, skipping import: ${src_dir}"
    return 0
  fi

  install -d -m 0750 "${OPENCLAW_OFFICIAL_HOME_DIR}"

  if [[ "${overwrite}" == "1" ]]; then
    warn "Personalization import is in override mode and will replace same-name files in ${OPENCLAW_OFFICIAL_HOME_DIR}"
    cp -af "${src_dir}/." "${OPENCLAW_OFFICIAL_HOME_DIR}/"
    log "Personalization override copy completed: ${src_dir} -> ${OPENCLAW_OFFICIAL_HOME_DIR}"
  else
    log "Personalization import is in non-override mode; existing files are preserved in ${OPENCLAW_OFFICIAL_HOME_DIR}"
    cp -an "${src_dir}/." "${OPENCLAW_OFFICIAL_HOME_DIR}/"
    log "Personalization copy completed without override: ${src_dir} -> ${OPENCLAW_OFFICIAL_HOME_DIR}"
  fi

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    owner_group="${ADMIN_USER}:${ADMIN_USER}"
  fi

  chown -R "${owner_group}" "${OPENCLAW_OFFICIAL_HOME_DIR}"
}

write_openclaw_bootstrap_json(){
  local json_path="${OPENCLAW_MAIN_CONFIG_JSON}"

  install -d -m 0750 "$(dirname "${json_path}")"

  if [[ -f "${json_path}" ]]; then
    warn "OpenClaw bootstrap JSON already exists, preserving: ${json_path}"
    return 0
  fi

  cat >"${json_path}" <<CFG
{
  "agents": {
    "defaults": {
      "workspace": "/root/.openclaw/workspace"
    }
  }
}
CFG

  chmod 0640 "${json_path}"
  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    chown "${ADMIN_USER}:${ADMIN_USER}" "${json_path}"
  fi
}
