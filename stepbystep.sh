好，这个需求非常对 👍（一行行跑更稳，不会再被 apt 锁 / 报错卡死）

我已经帮你把脚本（）**完全拆成可执行步骤版**👇
👉 直接复制一段一段执行就行

---

# 🚀 第 0 步：确保 root

```bash
sudo -i
```

---

# 🚀 第 1 步：系统检测（可选）

```bash
cat /etc/os-release
```

确认是：

```text
Ubuntu 24.04
```

---

# 🚀 第 2 步：更新系统（⚠️这步最慢）

```bash
apt-get update
```

👉 等跑完再执行：

```bash
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
```

---

# 🚀 第 3 步：安装基础工具（含 unzip）

```bash
apt-get install -y \
  curl wget git vim unzip \
  ufw fail2ban \
  ca-certificates gnupg lsb-release \
  openssh-server unattended-upgrades
```

---

# 🚀 第 4 步：开启自动安全更新

```bash
cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

---

# 🚀 第 5 步：内核优化（BBR + TCP）

```bash
cat >/etc/sysctl.d/99-zeabur.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.core.somaxconn=4096

vm.swappiness=10
vm.vfs_cache_pressure=50

net.ipv4.ip_forward=1
EOF
```

应用：

```bash
sysctl --system
```

---

# 🚀 第 6 步：创建 Swap（4G）

```bash
fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

开机自动挂载：

```bash
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

---

# 🚀 第 7 步：配置 Fail2ban

```bash
mkdir -p /etc/fail2ban
```

```bash
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
```

启动：

```bash
systemctl enable fail2ban --now
systemctl restart fail2ban
```

---

# 🚀 第 8 步：配置防火墙（UFW）

👉 ⚠️ 先开 SSH（防锁死）

```bash
ufw allow 22/tcp
```

然后：

```bash
ufw default deny incoming
ufw default allow outgoing
```

放行 Zeabur 端口：

```bash
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 4222/tcp
ufw allow 6443/tcp
ufw allow 30000:32767/tcp
ufw allow 30000:32767/udp
```

启用：

```bash
ufw --force enable
```

---

# 🚀 第 9 步：限制日志大小

```bash
mkdir -p /etc/systemd/journald.conf.d
```

```bash
cat >/etc/systemd/journald.conf.d/99-zeabur.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=100M
MaxRetentionSec=7day
EOF
```

应用：

```bash
systemctl restart systemd-journald
```

---

# 🚀 第 10 步：验证状态

```bash
sysctl net.ipv4.tcp_congestion_control
```

```bash
free -h
```

```bash
fail2ban-client status
```

```bash
ufw status
```

```bash
ss -tulpn | grep -E ':(22|80|443|4222|6443|30000)'
```

---

# ✅ 最终效果

你这一套跑完：

✔ BBR 开启
✔ TCP 优化
✔ Swap OK
✔ Fail2ban OK
✔ UFW + Zeabur端口 OK
✔ unzip 已安装

---
