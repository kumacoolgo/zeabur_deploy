#!/usr/bin/env bash

# ====================================================
# Zeabur Node Production Init Script
# Only for Ubuntu 24.04
# ====================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

trap 'echo "❌ 错误：脚本在第 ${LINENO} 行执行失败"; exit 1' ERR

SCRIPT_VERSION="1.0.1"
SWAP_SIZE="${SWAP_SIZE:-4G}"

log() {
  echo
  echo "===================================================="
  echo "$1"
  echo "===================================================="
}

die() {
  echo "❌ $1"
  exit 1
}

# 1. root 检查
if [[ "${EUID}" -ne 0 ]]; then
  die "请使用 root 权限运行"
fi

# 2. 系统检查（强制 24.04）
source /etc/os-release

if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
  die "当前系统 ${ID} ${VERSION_ID}，必须使用 Ubuntu 24.04"
fi

echo "✅ 系统检测通过：Ubuntu 24.04"

# 3. 更新系统
log "更新系统与基础包"

apt-get update
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

apt-get install -y \
  curl wget git vim ufw fail2ban \
  ca-certificates gnupg lsb-release \
  openssh-server

# 4. BBR + sysctl
log "配置 BBR"

cat >/etc/sysctl.d/99-zeabur.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

sysctl --system >/dev/null

# 5. Swap
log "配置 Swap (${SWAP_SIZE})"

if ! swapon --show | grep -q '^/swapfile'; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi

  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "Swap 已启用，跳过"
fi

# 6. Docker
log "安装 Docker"

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi

systemctl enable docker --now
systemctl is-active --quiet docker || die "Docker 启动失败"

mkdir -p /etc/docker

cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2"
}
EOF

systemctl restart docker

# 7. Fail2ban（永久封禁）
log "配置 Fail2ban（3次失败永久封禁）"

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = systemd
bantime = -1
findtime = 3600
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
EOF

systemctl enable fail2ban --now
systemctl restart fail2ban

# 8. UFW（已修复 sshd 问题）
log "配置 UFW"

# 用绝对路径，避免 PATH 问题
if [ -x /usr/sbin/sshd ]; then
  ssh_port="$(/usr/sbin/sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
else
  ssh_port=""
fi

ssh_port="${ssh_port:-22}"
echo "检测到 SSH 端口: ${ssh_port}"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${ssh_port}/tcp"

# Zeabur 必要端口
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 4222/tcp
ufw allow 6443/tcp
ufw allow 30000:32767/tcp
ufw allow 30000:32767/udp

ufw --force enable

# 9. journald 限制
log "限制日志大小"

mkdir -p /etc/systemd/journald.conf.d

cat >/etc/systemd/journald.conf.d/99-zeabur.conf <<EOF
[Journal]
SystemMaxUse=200M
SystemKeepFree=100M
MaxRetentionSec=7day
EOF

systemctl restart systemd-journald

# 10. 输出状态
log "完成"

echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "Swap:"
free -h | grep Swap || true

echo "Docker:"
docker --version

echo "Fail2ban:"
fail2ban-client status sshd || true

echo "UFW:"
ufw status verbose || true

echo
echo "✅ Zeabur 节点初始化完成"  cat >/etc/sysctl.d/99-zeabur.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=${SWAPPINESS}
vm.vfs_cache_pressure=${VFS_CACHE_PRESSURE}
fs.file-max=1048576
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
          *) die "dd 回退模式仅内置支持 1G/2G/4G/8G，请直接用这些值之一作为 SWAP_SIZE" ;;
        esac
      fi

      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
    else
      echo "/swapfile 已存在，直接启用"
    fi

    swapon /swapfile
  fi

  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

install_docker() {
  log "安装 Docker"

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
  else
    echo "Docker 已安装，跳过"
  fi

  systemctl enable docker --now
  systemctl is-active --quiet docker || die "Docker 启动失败"

  mkdir -p /etc/docker

  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF

  systemctl restart docker
  systemctl is-active --quiet docker || die "Docker 重启失败"
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
  systemctl is-active --quiet fail2ban || die "Fail2ban 启动失败"
}

configure_ufw() {
  log "配置 UFW"

  local ssh_port
  ssh_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  ssh_port="${ssh_port:-22}"

  echo "检测到 SSH 端口: ${ssh_port}"

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${ssh_port}/tcp"

  # Zeabur 要求端口
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 4222/tcp
  ufw allow 6443/tcp
  ufw allow 30000:32767/tcp
  ufw allow 30000:32767/udp

  ufw --force enable
}

configure_journald() {
  log "限制 journald 日志体积"

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
  log "初始化完成，输出状态"

  echo "脚本版本: ${SCRIPT_VERSION}"
  echo "系统版本: $(. /etc/os-release && echo "${PRETTY_NAME}")"
  echo "内核版本: $(uname -r)"
  echo "主机名  : $(hostname)"
  echo

  echo "BBR 状态:"
  sysctl net.ipv4.tcp_congestion_control
  sysctl net.core.default_qdisc
  echo

  echo "Swap 状态:"
  free -h | grep -i swap || true
  swapon --show || true
  echo

  echo "Docker 状态:"
  docker --version
  systemctl --no-pager --full status docker | sed -n '1,8p' || true
  echo

  echo "Fail2ban 状态:"
  fail2ban-client status || true
  echo
  fail2ban-client status sshd || true
  echo

  echo "UFW 状态:"
  ufw status verbose || true
  echo

  echo "监听端口概览:"
  ss -tulpn | grep -E ':(22|80|443|4222|6443|30000|32767)\b|Local Address' || true
  echo

  echo "✅ Zeabur 节点基础初始化完成"
}

main() {
  echo "Zeabur Node Production Init Script v${SCRIPT_VERSION}"
  require_root
  check_os
  check_resources
  apt_install_base
  configure_sysctl
  configure_swap
  install_docker
  configure_fail2ban
  configure_ufw
  configure_journald
  final_status
}

main "$@"
