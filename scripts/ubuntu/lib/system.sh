#!/usr/bin/env bash

apt_basics(){
  log "System update + baseline tools"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y \
    ca-certificates curl wget gnupg lsb-release \
    ufw fail2ban unattended-upgrades \
    chrony git jq tzdata unzip zip rsync tmux htop lsof vim util-linux
  systemctl enable --now chrony || true
}

set_identity(){
  log "Set hostname/timezone"
  hostnamectl set-hostname "$HOSTNAME_FQDN" || true
  timedatectl set-timezone "$TIMEZONE" || true
}

create_admin(){
  log "Create/verify admin user: $ADMIN_USER"
  if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
  fi

  if [[ -n "$SSH_PUBKEY" ]]; then
    log "Write SSH public key for $ADMIN_USER"
    install -d -m 700 "/home/$ADMIN_USER/.ssh"
    echo "$SSH_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
    chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  else
    warn "SSH_PUBKEY is not set: skipping password/root-SSH lockout to avoid losing access"
  fi
}

ssh_hardening(){
  log "SSH hardening"
  [[ -n "$SSH_PUBKEY" ]] || { echo "  Skipped (SSH_PUBKEY is empty)"; return 0; }

  install -d /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-openclaw.conf <<CFG
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
CFG

  systemctl restart ssh || systemctl restart sshd
}

firewall(){
  log "UFW: allow SSH only"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp"
  ufw --force enable
  ufw status verbose || true
}

fail2ban_cfg(){
  log "fail2ban: enable sshd protection"
  cat >/etc/fail2ban/jail.d/sshd.local <<'CFG'
[sshd]
enabled = true
bantime  = 1h
findtime = 10m
maxretry = 5
CFG
  systemctl enable --now fail2ban
}

unattended_upgrades(){
  log "Enable unattended-upgrades"
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
}

configure_zram(){
  local zram_gb
  local zram_mb

  [[ "${ENABLE_ZRAM:-1}" == "1" ]] || return 0

  zram_gb="$(awk -v r="${RAM_GB:-4}" 'BEGIN{v=int(0.25*r); if(v<1)v=1; if(v>8)v=8; printf "%d", v}')"
  zram_mb=$(( zram_gb * 1024 ))

  log "Configure zram (${zram_gb}GB, lz4, priority 100)"
  modprobe zram || true
  [[ -b /dev/zram0 ]] || return 0

  swapoff /dev/zram0 >/dev/null 2>&1 || true
  echo lz4 > /sys/block/zram0/comp_algorithm || true
  echo "${zram_mb}M" > /sys/block/zram0/disksize
  mkswap /dev/zram0
  swapon -p 100 /dev/zram0
}

swap_and_sysctl(){
  log "Configure swap + sysctl"

  if [[ "${ENABLE_SWAPFILE:-1}" == "1" ]]; then
    log "Configure swapfile (${SWAP_GB}GB)"
    if ! swapon --show | grep -q "/swapfile"; then
      fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1G count="${SWAP_GB}"
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi

  configure_zram

  cat >/etc/sysctl.d/99-openclaw.conf <<'CFG'
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
CFG

  sysctl --system
}

disable_thp(){
  log "Disable THP"
  cat >/etc/systemd/system/disable-thp.service <<'CFG'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -f /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true; test -f /sys/kernel/mm/transparent_hugepage/defrag && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
CFG

  systemctl daemon-reload
  systemctl enable --now disable-thp.service
}

raise_limits(){
  log "Increase nofile limits"

  cat >/etc/security/limits.d/99-openclaw.conf <<'CFG'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
CFG

  install -d /etc/systemd/system.conf.d
  cat >/etc/systemd/system.conf.d/99-openclaw.conf <<'CFG'
[Manager]
DefaultLimitNOFILE=65535
CFG

  systemctl daemon-reexec || true
}
