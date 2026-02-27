#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# OpenClaw Host Prep (Common)
#
# 从 “新建 Linode VM” 到 “安装 OpenClaw 前” 的主机底座：
# - SSH key-only（可选但强烈建议）、禁 root 远程、fail2ban
# - Tunnel 模式：UFW 只放行 SSH（不开放 80/443）
# - swap + sysctl + 关闭 THP + 提升 nofile
# - Docker（官方 APT 仓库：最新稳定）
# - cloudflared（Cloudflare 官方 APT 仓库：最新稳定）
# - 生成 /opt/openclaw/infra：pgvector(Postgres) + Valkey 的 compose（默认不启动）
###############################################################################

PROFILE="${OPENCLAW_PROFILE:-4gb}"                 # wrapper：4gb / 8gb
BOOTSTRAP_ENV="${BOOTSTRAP_ENV:-/opt/openclaw/bootstrap.env}"
START_INFRA="${START_INFRA:-0}"                    # 1=生成后直接 up -d

log(){ echo -e "\n[+] $*\n"; }
die(){ echo -e "\n[!] $*\n" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "请用 sudo 运行"; }

load_env(){
  [[ -f "$BOOTSTRAP_ENV" ]] || die "未找到 $BOOTSTRAP_ENV（请从 templates/bootstrap.env.example 复制并填写真实值）"
  set -a
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_ENV"
  set +a

  : "${ADMIN_USER:?ADMIN_USER 未设置}"
  : "${TIMEZONE:=America/Los_Angeles}"
  : "${HOSTNAME_FQDN:=openclaw-1}"
  : "${SSH_PORT:=22}"
  : "${OPENCLAW_BASE:=/opt/openclaw}"
  : "${SSH_PUBKEY:=}"  # 可为空：为空则跳过“禁密码/禁 root”以避免锁死

  : "${POSTGRES_DB:=openclaw}"
  : "${POSTGRES_USER:=openclaw}"
  : "${POSTGRES_PASSWORD:=CHANGE_ME_STRONG}"
  : "${PGVECTOR_IMAGE:=pgvector/pgvector:pg18-trixie}"
  : "${VALKEY_IMAGE:=valkey/valkey:9}"
}

os_check(){
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "当前系统不是 Ubuntu（ID=${ID:-unknown}）。建议 Ubuntu 24.04 LTS 或更新。"
  command -v dpkg >/dev/null 2>&1 || die "缺少 dpkg"
  dpkg --compare-versions "${VERSION_ID}" ge "24.04" || die "Ubuntu 版本过旧：${VERSION_ID}，请用 24.04+"
}

apply_profile_defaults(){
  if [[ "$PROFILE" == "8gb" ]]; then
    : "${SWAP_GB:=4}"
    : "${POSTGRES_MEM_LIMIT:=2200m}"
    : "${POSTGRES_SHM_SIZE:=512mb}"
    : "${VALKEY_MEM_LIMIT:=512m}"
    : "${VALKEY_MAXMEM:=384mb}"

    : "${PG_SHARED_BUFFERS:=512MB}"
    : "${PG_EFFECTIVE_CACHE_SIZE:=2048MB}"
    : "${PG_WORK_MEM:=16MB}"
    : "${PG_MAINTENANCE_WORK_MEM:=256MB}"
    : "${PG_MAX_CONNECTIONS:=120}"
  else
    : "${SWAP_GB:=2}"
    : "${POSTGRES_MEM_LIMIT:=1100m}"
    : "${POSTGRES_SHM_SIZE:=256mb}"
    : "${VALKEY_MEM_LIMIT:=256m}"
    : "${VALKEY_MAXMEM:=192mb}"

    : "${PG_SHARED_BUFFERS:=256MB}"
    : "${PG_EFFECTIVE_CACHE_SIZE:=768MB}"
    : "${PG_WORK_MEM:=16MB}"
    : "${PG_MAINTENANCE_WORK_MEM:=128MB}"
    : "${PG_MAX_CONNECTIONS:=80}"
  fi
}

apt_basics(){
  log "系统更新 + 基础工具"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    ufw fail2ban unattended-upgrades \
    chrony git jq htop vim
  systemctl enable --now chrony || true
}

set_identity(){
  log "设置主机名/时区"
  hostnamectl set-hostname "$HOSTNAME_FQDN" || true
  timedatectl set-timezone "$TIMEZONE" || true
}

create_admin(){
  log "创建/确认管理员用户：$ADMIN_USER"
  if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
  fi

  if [[ -n "$SSH_PUBKEY" ]]; then
    log "写入 $ADMIN_USER 的 SSH 公钥（authorized_keys）"
    install -d -m 700 "/home/$ADMIN_USER/.ssh"
    echo "$SSH_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
    chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  else
    log "未设置 SSH_PUBKEY：将跳过“禁密码/禁 root 远程”，避免锁死。建议尽快补上。"
  fi
}

ssh_hardening(){
  log "SSH 加固（有 SSH_PUBKEY 才启用）"
  [[ -n "$SSH_PUBKEY" ]] || { echo "    跳过"; return 0; }

  install -d /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-openclaw.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowUsers ${ADMIN_USER}
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 4
EOF

  systemctl restart ssh || systemctl restart sshd
}

firewall(){
  log "UFW：Tunnel 模式仅放行 SSH（不开放 80/443）"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp"
  ufw --force enable
  ufw status verbose || true
}

fail2ban_cfg(){
  log "fail2ban：SSH 防爆破"
  cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
bantime  = 1h
findtime = 10m
maxretry = 5
EOF
  systemctl enable --now fail2ban
}

unattended_upgrades(){
  log "启用自动安全更新"
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
}

swap_and_sysctl(){
  log "Swap(${SWAP_GB}GB) + sysctl（含 Valkey/Redis 推荐项）"
  if ! swapon --show | grep -q "/swapfile"; then
    fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1G count="${SWAP_GB}"
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  cat >/etc/sysctl.d/99-openclaw.conf <<'EOF'
vm.overcommit_memory=1
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.ip_local_port_range=10240 65535
fs.file-max=1048576
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system
}

disable_thp(){
  log "关闭 THP（减少 Valkey/Redis 延迟抖动）"
  cat >/etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -f /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true; test -f /sys/kernel/mm/transparent_hugepage/defrag && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now disable-thp.service
}

raise_limits(){
  log "提高 nofile（多连接更稳）"
  cat >/etc/security/limits.d/99-openclaw.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

  install -d /etc/systemd/system.conf.d
  cat >/etc/systemd/system.conf.d/99-openclaw.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=65535
EOF
  systemctl daemon-reexec || true
}

install_docker_latest(){
  log "安装 Docker（官方 APT 仓库：最新稳定）"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker

  install -d /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
  systemctl restart docker
  usermod -aG docker "$ADMIN_USER" || true
}

install_cloudflared_latest(){
  log "安装 cloudflared（Cloudflare 官方 APT 仓库：最新稳定）"
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y
  apt-get install -y cloudflared
}

render_infra(){
  log "生成 /opt/openclaw/infra（pgvector + valkey）"
  local infra_dir="${OPENCLAW_BASE}/infra"
  install -d -m 750 "${infra_dir}/db-init" "${OPENCLAW_BASE}/data" "${OPENCLAW_BASE}/backups"

  # 初始化 pgvector 扩展
  cat >"${infra_dir}/db-init/01-pgvector.sql" <<'EOF'
CREATE EXTENSION IF NOT EXISTS vector;
EOF

  # 生成 .env（避免把密码写进 compose 文件；权限 600）
  cat >"${infra_dir}/.env" <<EOF
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

PGVECTOR_IMAGE=${PGVECTOR_IMAGE}
VALKEY_IMAGE=${VALKEY_IMAGE}

POSTGRES_SHM_SIZE=${POSTGRES_SHM_SIZE}
POSTGRES_MEM_LIMIT=${POSTGRES_MEM_LIMIT}
VALKEY_MEM_LIMIT=${VALKEY_MEM_LIMIT}
VALKEY_MAXMEM=${VALKEY_MAXMEM}

PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS}
PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE}
PG_WORK_MEM=${PG_WORK_MEM}
PG_MAINTENANCE_WORK_MEM=${PG_MAINTENANCE_WORK_MEM}
PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS}
EOF
  chmod 600 "${infra_dir}/.env"

  cat >"${infra_dir}/docker-compose.infra.yml" <<'EOF'
services:
  postgres:
    image: ${PGVECTOR_IMAGE}
    restart: unless-stopped
    shm_size: ${POSTGRES_SHM_SIZE}
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./db-init:/docker-entrypoint-initdb.d:ro
    command:
      - "postgres"
      - "-c"
      - "shared_buffers=${PG_SHARED_BUFFERS}"
      - "-c"
      - "effective_cache_size=${PG_EFFECTIVE_CACHE_SIZE}"
      - "-c"
      - "work_mem=${PG_WORK_MEM}"
      - "-c"
      - "maintenance_work_mem=${PG_MAINTENANCE_WORK_MEM}"
      - "-c"
      - "max_connections=${PG_MAX_CONNECTIONS}"
    mem_limit: ${POSTGRES_MEM_LIMIT}

  valkey:
    image: ${VALKEY_IMAGE}
    restart: unless-stopped
    command: >
      valkey-server
      --save 60 1
      --appendonly yes
      --maxmemory ${VALKEY_MAXMEM}
      --maxmemory-policy allkeys-lru
    volumes:
      - valkey_data:/data
    mem_limit: ${VALKEY_MEM_LIMIT}

volumes:
  pg_data:
  valkey_data:
EOF
}

maybe_start_infra(){
  [[ "$START_INFRA" == "1" ]] || return 0
  log "启动 infra（pgvector + valkey）"
  ( cd "${OPENCLAW_BASE}/infra" && docker compose -f docker-compose.infra.yml up -d )
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

main(){
  need_root
  load_env
  os_check
  apply_profile_defaults

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
  maybe_start_infra

  log "完成 ✅（已到“安装 OpenClaw 前”的状态）"
  echo "下一步："
  echo "  -（可选）启动 infra：START_INFRA=1 sudo -E bash scripts/linode/prep_${PROFILE}.sh"
  echo "  - 配 Cloudflare Tunnel：sudo bash scripts/cloudflare/setup_tunnel.sh"
}

main "$@"
