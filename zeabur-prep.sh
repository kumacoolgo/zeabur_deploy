#!/usr/bin/env bash

# ====================================================
# Zeabur Node Production Init Script (Custom)
# Only for Ubuntu 24.04
# 优化版（按你的需求裁剪）
# ====================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

trap 'echo "❌ 错误：脚本在第 ${LINENO} 行执行失败"; exit 1' ERR

SCRIPT_VERSION="2.0.0"

SWAP_SIZE="${SWAP_SIZE:-4G}"
SWAPPINESS="${SWAPPINESS:-10}"
VFS_CACHE_PRESSURE="${VFS_CACHE_PRESSURE:-50}"

log() {
  echo
  echo "===================================================="
  echo "$1"
  echo "===================================================="
}

warn() {
  echo "⚠️  $1"
}

die() {
  echo "❌ $1"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 权限运行此脚本"
  fi
}

check_os() {
  [[ -f /etc/os-release ]] || die "无法识别系统：/etc/os-release 不存在"
  source /etc/os-release

  if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
    die "当前系统为 ${ID:-unknown} ${VERSION_ID:-unknown}，仅支持 Ubuntu 24.04"
  fi

  echo "✅ 系统检测通过：Ubuntu 24.04"
}

check_resources() {
  log "检查基础资源"

  local mem_mb cpu_count
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  cpu_count="$(nproc)"

  echo "内存: ${mem_mb} MB"
  echo "CPU : ${cpu_count} 核"

  if (( mem_mb < 1800 )); then
    warn "当前内存低于 2GB，可能不满足 Zeabur 最低要求"
  fi
}

apt_install_base() {
  log "更新系统与基础包"

  apt-get update
  apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  apt-get install -y \
    curl \
    wget \
    git \
    vim \
    ufw \
    fail2ban \
    ca-certificates \
    gnupg \
    lsb-release \
    openssh-server \
    unattended-upgrades \
    unzip

  apt-get autoremove -y
  apt-get autoclean -y

  # 自动安全更新
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

configure_sysctl() {
  log "配置内核参数（BBR + TCP优化）"

  cat >/etc/sysctl.d/99-zeabur.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.core.somaxconn=4096

vm.swappiness=${SWAPPINESS}
vm.vfs_cache_pressure=${VFS_CACHE_PRESSURE}

net.ipv4.ip_forward=1
EOF

  sysctl --system >/dev/null
}

configure_swap() {
  log "配置 Swap (${SWAP_SIZE})"

  if swapon --show | grep -q '^/swapfile'; then
    echo "Swap 已启用，跳过创建"
  else
    if [[ ! -f /swapfile ]]; then
      if ! fallocate -l "${SWAP_SIZE}" /swapfile; then
        warn "fallocate 失败，改用 dd 创建 swapfile"
        case "${SWAP_SIZE}" in
          1G) dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress ;;
          2G) dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress ;;
          4G) dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress ;;
          8G) dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress ;;
          *) die "dd 模式仅支持 1G/2G/4G/8G" ;;
        esac
      fi

      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
    fi

    swapon /swapfile
  fi

  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

configure_fail2ban() {
  log "配置 Fail2ban（3次失败永久封禁）"

  mkdir -p /etc/fail2ban

  cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
bantime = -1
findtime = 3600
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
EOF

  systemctl enable fail2ban --now
  systemctl restart fail2ban
}

configure_ufw() {
  log "配置 UFW"
  echo "SSH 端口: 22"

  ufw default deny incoming
  ufw default allow outgoing

  ufw allow 22/tcp

  # Zeabur 必需端口
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 4222/tcp
  ufw allow 6443/tcp
  ufw allow 30000:32767/tcp
  ufw allow 30000:32767/udp

  ufw --force enable
}

configure_journald() {
  log "限制 journald 日志"

  mkdir -p /etc/systemd/journald.conf.d

  cat >/etc/systemd/journald.conf.d/99-zeabur.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=100M
MaxRetentionSec=7day
EOF

  systemctl restart systemd-journald
}

final_status() {
  log "初始化完成"

  echo "脚本版本: ${SCRIPT_VERSION}"
  echo "系统版本: $(. /etc/os-release && echo "${PRETTY_NAME}")"
  echo "内核版本: $(uname -r)"
  echo

  echo "BBR:"
  sysctl net.ipv4.tcp_congestion_control
  echo

  echo "Swap:"
  free -h | grep -i swap || true
  echo

  echo "Fail2ban:"
  fail2ban-client status || true
  echo

  echo "UFW:"
  ufw status verbose || true
  echo

  echo "端口监听:"
  ss -tulpn | grep -E ':(22|80|443|4222|6443|30000)' || true
  echo

  echo "✅ 初始化完成"
}

main() {
  echo "Zeabur Init Script v${SCRIPT_VERSION}"

  require_root
  check_os
  check_resources
  apt_install_base
  configure_sysctl
  configure_swap
  configure_fail2ban
  configure_ufw
  configure_journald
  final_status
}

main "$@"
