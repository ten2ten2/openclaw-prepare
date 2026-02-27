#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Linode 8GB 基础底座（到安装 OpenClaw 前）
# 同 4GB 版，但资源默认更宽松
###############################################################################

### ===== 你必须按需修改的变量 =====
ADMIN_USER="op"
SSH_PUBKEY="ssh-ed25519 AAAA...替换成你的公钥... user@host"
SSH_PORT="22"
TIMEZONE="America/Los_Angeles"
HOSTNAME_FQDN="openclaw-8g-1"

# 8GB 机器建议 swap：4GB（更抗突发峰值）
SWAP_GB="4"

OPENCLAW_BASE="/opt/openclaw"
INFRA_DIR="${OPENCLAW_BASE}/infra"
### ==================================

log(){ echo -e "\n[+] $*\n"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "请用 sudo 运行"; exit 1; }; }
os_check(){ . /etc/os-release; [[ "${ID}" == "ubuntu" ]] || { echo "此脚本按 Ubuntu 编写"; exit 1; }; }

apt_basics(){
  log "系统更新 + 常用工具"
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
  hostnamectl set-hostname "${HOSTNAME_FQDN}" || true
  timedatectl set-timezone "${TIMEZONE}" || true
}

create_admin(){
  log "创建管理员用户：${ADMIN_USER}"
  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
    usermod -aG sudo "${ADMIN_USER}"
  fi
  if [[ -z "${SSH_PUBKEY}" || "${SSH_PUBKEY}" == *"替换成你的公钥"* ]]; then
    log "未填写 SSH_PUBKEY：跳过写入 authorized_keys（后续也会跳过 SSH 加固，避免锁死）"
    return 0
  fi
  install -d -m 700 "/home/${ADMIN_USER}/.ssh"
  echo "${SSH_PUBKEY}" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
}

ssh_hardening(){
  log "SSH 加固（仅当已配置 SSH_PUBKEY 才启用）"
  if [[ -z "${SSH_PUBKEY}" || "${SSH_PUBKEY}" == *"替换成你的公钥"* ]]; then
    echo "跳过 SSH 加固（未设置 SSH_PUBKEY）"
    return 0
  fi
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
  log "UFW：仅放行 SSH（Tunnel 模式不需要 80/443 入站）"
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
  log "创建 swapfile（${SWAP_GB}GB）+ sysctl"
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
  log "关闭 THP（减少 Valkey 延迟抖动）"
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
  log "提高 nofile"
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
  log "安装 Docker（官方仓库最新版）"
  # Docker 官方文档：Ubuntu 安装 docker-ce/docker-compose-plugin :contentReference[oaicite:7]{index=7}
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
  usermod -aG docker "${ADMIN_USER}" || true
}

install_cloudflared_latest(){
  log "安装 cloudflared（官方仓库最新版）"
  # Cloudflare 官方包仓库 :contentReference[oaicite:8]{index=8}
  install -d --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y
  apt-get install -y cloudflared
  cloudflared --version || true
}

prep_dirs_and_infra_templates(){
  log "创建目录 + 生成 infra compose（不启动）"
  install -d -m 750 "${INFRA_DIR}/db-init"
  install -d -m 750 "${OPENCLAW_BASE}/data" "${OPENCLAW_BASE}/backups"

  cat >"${INFRA_DIR}/db-init/01-pgvector.sql" <<'EOF'
CREATE EXTENSION IF NOT EXISTS vector;
EOF

  # 8GB：默认给 Postgres/Valkey 更宽松
  cat >"${INFRA_DIR}/docker-compose.infra.yml" <<'EOF'
services:
  postgres:
    image: pgvector/pgvector:pg18-trixie
    restart: unless-stopped
    shm_size: 512mb
    environment:
      - POSTGRES_DB=openclaw
      - POSTGRES_USER=openclaw
      - POSTGRES_PASSWORD=change_me
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./db-init:/docker-entrypoint-initdb.d:ro
    command:
      - "postgres"
      - "-c" ; "shared_buffers=512MB"
      - "-c" ; "effective_cache_size=2048MB"
      - "-c" ; "work_mem=16MB"
      - "-c" ; "maintenance_work_mem=256MB"
      - "-c" ; "max_connections=120"
    mem_limit: 2200m

  valkey:
    image: valkey/valkey:9
    restart: unless-stopped
    command: >
      valkey-server
      --save 60 1
      --appendonly yes
      --maxmemory 384mb
      --maxmemory-policy allkeys-lru
    volumes:
      - valkey_data:/data
    mem_limit: 512m

volumes:
  pg_data:
  valkey_data:
EOF
}

finish(){
  log "完成 ✅（到安装 OpenClaw 前的主机底座已就绪）"
  echo "可选：启动依赖（仍属于 OpenClaw 前置依赖）："
  echo "  cd ${INFRA_DIR} && docker compose -f docker-compose.infra.yml up -d"
}

main(){
  need_root
  os_check
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
  prep_dirs_and_infra_templates
  finish
}
main "$@"
