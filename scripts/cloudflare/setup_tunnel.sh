#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Cloudflare Tunnel（单 Web 后台，无反代）
# - 读取 /opt/openclaw/bootstrap.env（不入库）
# - 将 https://CF_HOSTNAME 转发到本机 CF_LOCAL_URL（必须是 127.0.0.1 或 Docker 内网）
# - 安装为 systemd 服务：cloudflared
###############################################################################

BOOTSTRAP_ENV="${BOOTSTRAP_ENV:-/opt/openclaw/bootstrap.env}"

die(){ echo -e "\n[!] $*\n" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "请用 sudo 运行"; }
log(){ echo -e "\n[+] $*\n"; }

load_env(){
  [[ -f "$BOOTSTRAP_ENV" ]] || die "未找到 $BOOTSTRAP_ENV（请从 templates/bootstrap.env.example 复制并填写真实值）"
  set -a
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_ENV"
  set +a

  : "${CF_RUN_USER:?CF_RUN_USER 未设置}"
  : "${CF_TUNNEL_NAME:?CF_TUNNEL_NAME 未设置}"
  : "${CF_HOSTNAME:?CF_HOSTNAME 未设置}"
  : "${CF_LOCAL_URL:?CF_LOCAL_URL 未设置}"
}

get_tunnel_uuid(){
  sudo -u "${CF_RUN_USER}" -H bash -lc \
    "cloudflared tunnel list --output json" \
    | jq -r ".[] | select(.name==\"${CF_TUNNEL_NAME}\") | .id" \
    | head -n1
}

main(){
  need_root
  load_env

  command -v cloudflared >/dev/null 2>&1 || die "未安装 cloudflared（先跑 scripts/linode/prep_4gb.sh 或 prep_8gb.sh）"
  command -v jq >/dev/null 2>&1 || die "缺少 jq（prep 脚本会安装）"

  log "Cloudflare 登录（会输出授权 URL，用浏览器打开完成授权）"
  sudo -u "${CF_RUN_USER}" -H bash -lc "cloudflared tunnel login"

  log "创建 Tunnel：${CF_TUNNEL_NAME}"
  set +e
  out="$(sudo -u "${CF_RUN_USER}" -H bash -lc "cloudflared tunnel create ${CF_TUNNEL_NAME}" 2>&1)"
  rc=$?
  set -e

  UUID=""
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    UUID="$(echo "$out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1)"
  else
    echo "$out"
    UUID="$(get_tunnel_uuid || true)"
  fi
  [[ -n "$UUID" ]] || die "未解析到 Tunnel UUID（可手动运行：cloudflared tunnel list）"

  log "写入 /etc/cloudflared/config.yml"
  install -d /etc/cloudflared

  cred="/home/${CF_RUN_USER}/.cloudflared/${UUID}.json"
  [[ -f "$cred" ]] || die "找不到凭据文件：$cred（确认 CF_RUN_USER 的 home 与 login 是否成功）"
  install -m 600 "$cred" "/etc/cloudflared/${UUID}.json"

  cat >/etc/cloudflared/config.yml <<EOF
tunnel: ${UUID}
credentials-file: /etc/cloudflared/${UUID}.json

ingress:
  - hostname: ${CF_HOSTNAME}
    service: ${CF_LOCAL_URL}
  - service: http_status:404
EOF

  log "创建/更新 DNS 路由：${CF_HOSTNAME} -> Tunnel"
  sudo -u "${CF_RUN_USER}" -H bash -lc "cloudflared tunnel route dns ${CF_TUNNEL_NAME} ${CF_HOSTNAME}" || true

  log "安装 systemd 服务并启动"
  cloudflared --config /etc/cloudflared/config.yml service install || true
  systemctl enable --now cloudflared
  systemctl status cloudflared --no-pager

  log "完成 ✅ 访问：https://${CF_HOSTNAME}"
  echo "注意：Web 后台务必只监听 127.0.0.1（或 docker 仅映射到 127.0.0.1）"
}

main "$@"
