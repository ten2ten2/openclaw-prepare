#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_ENV="${BOOTSTRAP_ENV:-/opt/openclaw/bootstrap.env}"

die(){ echo -e "\n[!] $*\n" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "请用 sudo 运行"; }
log(){ echo -e "\n[+] $*\n"; }

load_env(){
  [[ -f "$BOOTSTRAP_ENV" ]] || die "未找到 $BOOTSTRAP_ENV ，请先创建并填写（见 templates/bootstrap.env.example）。"
  set -a
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_ENV"
  set +a

  : "${CF_RUN_USER:?CF_RUN_USER 未设置}"
  : "${CF_TUNNEL_NAME:?CF_TUNNEL_NAME 未设置}"
  : "${CF_HOSTNAME:?CF_HOSTNAME 未设置}"
  : "${CF_LOCAL_URL:?CF_LOCAL_URL 未设置}"
}

main(){
  need_root
  load_env

  command -v cloudflared >/dev/null 2>&1 || die "未安装 cloudflared。请先运行 scripts/linode/prep_4gb.sh 或 prep_8gb.sh"

  log "Cloudflare 登录（会输出一个 URL，用浏览器打开完成授权）"
  sudo -u "${CF_RUN_USER}" -H bash -lc "cloudflared tunnel login"

  log "创建 Tunnel：${CF_TUNNEL_NAME}"
  out="$(sudo -u "${CF_RUN_USER}" -H bash -lc "cloudflared tunnel create ${CF_TUNNEL_NAME}")"
  echo "$out"

  UUID="$(echo "$out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1)"
  [[ -n "${UUID}" ]] || die "未解析到 Tunnel UUID。可用：cloudflared tunnel list"

  log "写入 /etc/cloudflared/config.yml"
  install -d /etc/cloudflared

  # credentials json 存放到 /etc/cloudflared（敏感文件，切勿提交仓库）
  install -m 600 "/home/${CF_RUN_USER}/.cloudflared/${UUID}.json" "/etc/cloudflared/${UUID}.json"

  cat >/etc/cloudflared/config.yml <<EOF
tunnel: ${UUID}
credentials-file: /etc/cloudflared/${UUID}.json

ingress:
  - hostname: ${CF_HOSTNAME}
    service: ${CF_LOCAL_URL}
  - service: http_status:404
EOF

  log "创建 DNS 路由：${CF_HOSTNAME} -> Tunnel"
  sudo -u "${CF_RUN_USER}" -H bash -lc "cloudflared tunnel route dns ${CF_TUNNEL_NAME} ${CF_HOSTNAME}"

  log "安装 systemd 服务并启动"
  cloudflared --config /etc/cloudflared/config.yml service install
  systemctl enable --now cloudflared
  systemctl status cloudflared --no-pager

  log "完成 ✅ 访问：https://${CF_HOSTNAME}"
  echo "注意：你的 Web 后台应仅监听 127.0.0.1（或 docker 仅映射到 127.0.0.1）。"
}

main "$@"
