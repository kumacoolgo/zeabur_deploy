#!/bin/bash

# ====================================================
# Zeabur Node Pre-config Script (Ubuntu/Debian)
# 功能：系统更新 (静默模式), BBR, Swap, Docker, UFW, Fail2ban
# ====================================================

# 开启静默模式，防止 apt 弹窗卡死
export DEBIAN_FRONTEND=noninteractive
set -e

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (sudo su)"
  exit 1
fi

# 2. 识别系统
ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
VERSION_ID=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')

echo "检测到系统: $ID $VERSION_ID"

# 3. 更新系统与基础包 (使用强制默认配置参数)
echo "--- 正在更新系统资源 (过程较慢，请稍候) ---"
apt update
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -y curl wget git vim ufw fail2ban software-properties-common ca-certificates apt-transport-https

# 4. 开启 TCP BBR 加速
echo "--- 配置 TCP BBR ---"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
fi

# 5. 配置 4G 虚拟内存 (Swap)
echo "--- 配置 4G Swap ---"
if [ ! -f /swapfile ]; then
  # 优先使用 fallocate，失败则使用 dd
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "Swap 已存在，跳过"
fi

# 6. 安装 Docker
echo "--- 安装 Docker ---"
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | bash
  systemctl enable docker --now
else
  echo "Docker 已安装，跳过"
fi

# 7. 配置 Fail2Ban (3次错误永久封禁)
echo "--- 配置 Fail2Ban (3次报错永久封禁) ---"
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = -1
findtime = 3600
EOF
systemctl restart fail2ban

# 8. 配置 UFW 防火墙 (针对 Zeabur 优化)
echo "--- 配置 UFW 规则 ---"
# 先重置规则确保干净
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# 开放端口
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 4222/tcp
ufw allow 6443/tcp
ufw allow 30000:32767/tcp
ufw allow 30000:32767/udp
# 强制开启
echo "y" | ufw enable

echo "------------------------------------------------"
echo "✅ 配置完成！你的服务器已准备好接入 Zeabur。"
echo "BBR 状态: $(sysctl net.ipv4.tcp_congestion_control)"
echo "Swap 状态: $(free -h | grep Swap)"
echo "Docker 版本: $(docker --version)"
echo "------------------------------------------------"
