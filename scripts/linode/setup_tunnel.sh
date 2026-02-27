#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Cloudflare Tunnel（单 Web 后台，无反代）
# - 将 https://admin.example.com 转发到本机 http://127.0.0.1:3000
# - 安装为 systemd 服务：cloudflared
# 注意：会执行 cloudflared tunnel login（会输出一个浏览器授权链接）
###############################################################################

### ===== 按需修改 =====
RUN_USER="op"
TUNNEL_NAME="openclaw-admin"
HOSTNAME="admin.example.com"
LOCAL_URL="http://127.0.0.1:3000"   # 你的 Web 后台必须只监听本机（不要绑定 0.0.0.0）
### ===================

need_root(){ [[ $EUID -eq 0 ]] || { echo "请用 sudo 运行"; exit 1; }; }
log(){ echo -e "\n[+] $*\n"; }

main(){
  need_root
  command -v cloudflared >/dev/null 2>&1 || { echo "未安装 cloudflared，请先跑 4GB/8GB 底座脚本"; exit 1; }

  log "Cloudflare 登录（会输出授权 URL，浏览器打开确认）"
  sudo -u "${RUN_USER}" -H bash -lc "cloudflared tunnel login"

  log "创建 Tunnel：${TUNNEL_NAME}"
  out="$(sudo -u "${RUN_USER}" -H bash -lc "cloudflared tunnel create ${TUNNEL_NAME}")"
  echo "${out}"

  UUID="$(echo "${out}" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1)"
  [[ -n "${UUID}" ]] || { echo "未解析到 UUID，可用 cloudflared tunnel list 查看"; exit 1; }
  log "Tunnel UUID: ${UUID}"

  log "写入 /etc/cloudflared/config.yml"
  install -d /etc/cloudflared
  install -m 600 "/home/${RUN_USER}/.cloudflared/${UUID}.json" "/etc/cloudflared/${UUID}.json"

  cat >/etc/cloudflared/config.yml <<EOF
tunnel: ${UUID}
credentials-file: /etc/cloudflared/${UUID}.json

ingress:
  - hostname: ${HOSTNAME}
    service: ${LOCAL_URL}
  - service: http_status:404
EOF

  log "创建 DNS 路由：${HOSTNAME} -> Tunnel"
  sudo -u "${RUN_USER}" -H bash -lc "cloudflared tunnel route dns ${TUNNEL_NAME} ${HOSTNAME}"

  log "安装 systemd 服务并启动"
  cloudflared --config /etc/cloudflared/config.yml service install
  systemctl enable --now cloudflared
  systemctl status cloudflared --no-pager
  log "完成：访问 https://${HOSTNAME}"
}

main "$@"
