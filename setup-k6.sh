#!/usr/bin/env bash
# setup-k6.sh — เตรียมเครื่อง Ubuntu 24.04 ใหม่ให้เป็น load generator สำหรับ k6
# วิธีใช้: sudo ./setup-k6.sh  แล้ว reboot 1 ครั้ง
set -euo pipefail

# CONFIG
K6_VERSION="1.8.1"        # pin version ให้ตรงกันทุกเครื่องยิง
NOFILE_LIMIT="65535"      # เพียงพอสำหรับเครื่อง 16GB (RAM หมดก่อน fd หมด)
TIMEZONE="Asia/Bangkok"
INSTALL_NODE="1"          # 1 = ติดตั้ง Node.js LTS (ใช้รัน insertdata.js), 0 = ข้าม

# ตรวจสอบสิทธิ์และ OS
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] ต้องรันด้วย sudo" >&2
  exit 1
fi
if ! grep -q 'VERSION_ID="24.04"' /etc/os-release; then
  echo "[WARN] สคริปต์นี้ทดสอบกับ Ubuntu 24.04 เท่านั้น" >&2
fi

# 1. อัปเดตระบบ + เครื่องมือ diagnostic
echo "[1/6] อัปเดตระบบและติดตั้งเครื่องมือ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  ca-certificates curl gnupg jq git unzip \
  netcat-openbsd dnsutils traceroute openssl iproute2 \
  htop sysstat chrony

# 2. ตั้งเวลา + NTP (ให้ timestamp ตรงกับ log ฝั่ง server และเครื่องยิงอื่น)
echo "[2/6] ตั้ง timezone และ NTP..."
timedatectl set-timezone "$TIMEZONE"
systemctl enable --now chrony

# 3. ติดตั้ง k6 แบบ pin version
echo "[3/6] ติดตั้ง k6 v${K6_VERSION}..."
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list
apt-get update -y
if ! grep -q " ${K6_VERSION} " <<< "$(apt-cache madison k6)"; then
  echo "[ERROR] ไม่พบ k6 version ${K6_VERSION} ใน repo — version ที่มี:" >&2
  apt-cache madison k6 | head -n 10 >&2
  exit 1
fi
apt-get install -y --allow-downgrades "k6=${K6_VERSION}"
apt-mark hold k6   # กัน apt upgrade เปลี่ยน version โดยไม่ตั้งใจ

# 4. File descriptor limit แบบถาวร (ครอบทั้ง login session และ systemd service)
echo "[4/6] ตั้ง nofile = ${NOFILE_LIMIT}..."
cat > /etc/security/limits.d/99-k6.conf <<EOF
*    soft  nofile  ${NOFILE_LIMIT}
*    hard  nofile  ${NOFILE_LIMIT}
root soft  nofile  ${NOFILE_LIMIT}
root hard  nofile  ${NOFILE_LIMIT}
EOF
install -d /etc/systemd/system.conf.d /etc/systemd/user.conf.d
printf "[Manager]\nDefaultLimitNOFILE=%s\n" "$NOFILE_LIMIT" > /etc/systemd/system.conf.d/99-k6.conf
printf "[Manager]\nDefaultLimitNOFILE=%s\n" "$NOFILE_LIMIT" > /etc/systemd/user.conf.d/99-k6.conf

# 5. Network kernel tuning — เอาคอขวดฝั่ง client ออก (ต้องตั้งเหมือนกันทุกเครื่องยิง)
echo "[5/6] ตั้งค่า sysctl..."
cat > /etc/sysctl.d/99-k6.conf <<EOF
# ขยาย ephemeral port (default 24.04 = 32768-60999 ~28k port ต่อ target)
net.ipv4.ip_local_port_range = 1024 65535
# reuse socket ที่อยู่ใน TIME_WAIT สำหรับ outbound connection
net.ipv4.tcp_tw_reuse = 1
# ลดเวลาค้างของ socket ตอนปิด connection
net.ipv4.tcp_fin_timeout = 15
# backlog สำหรับ connection จำนวนมาก
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384
fs.file-max = 2097152
# กันเครื่องยิง swap — ถ้า swap ค่า latency ที่ k6 วัดจะเพี้ยน
vm.swappiness = 10
EOF
sysctl --system > /dev/null

# 6. Node.js LTS (optional)
if [[ "$INSTALL_NODE" == "1" ]] && command -v node > /dev/null; then
  echo "[6/6] มี Node.js อยู่แล้ว ($(node -v)) — ข้าม ไม่เปลี่ยน version"
elif [[ "$INSTALL_NODE" == "1" ]]; then
  echo "[6/6] ติดตั้ง Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
else
  echo "[6/6] ข้าม Node.js"
fi

# สรุปผล
echo
echo "===== สรุป ====="
echo "k6:            $(k6 version | head -n 1)"
[[ "$INSTALL_NODE" == "1" ]] && echo "node:          $(node -v)"
echo "timezone:      $(timedatectl show -p Timezone --value)"
echo "ntp synced:    $(timedatectl show -p NTPSynchronized --value)"
echo "port range:    $(sysctl -n net.ipv4.ip_local_port_range)"
echo "tcp_tw_reuse:  $(sysctl -n net.ipv4.tcp_tw_reuse)"
echo "swappiness:    $(sysctl -n vm.swappiness)"
echo "nofile config: ${NOFILE_LIMIT} (มีผลหลัง reboot / login ใหม่)"
echo
echo ">>> กรุณา reboot: sudo reboot"
echo ">>> หลัง reboot เช็ค: ulimit -n  (ต้องได้ ${NOFILE_LIMIT})"
