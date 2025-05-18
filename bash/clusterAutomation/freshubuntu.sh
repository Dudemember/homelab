#!/usr/bin/env bash
set -euo pipefail

# ----- Configuration -----
USER=labuser
PASS_FILE="$(dirname "$0")/labuser.pass"
DEVICE=/dev/sda
MOUNTPOINT=/data

# 0) Read labuser password
if [[ ! -s "$PASS_FILE" ]]; then
  echo "ERROR: missing or empty $PASS_FILE" >&2
  exit 1
fi
PASS=$(<"$PASS_FILE")

# 1) Install & enable SSH, parted
apt-get update
apt-get install -y openssh-server parted
systemctl enable --now ssh

# 2) Create labuser + passwordless sudo  
if ! id "$USER" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "$USER"
  echo "$USER:$PASS" | chpasswd
fi
cat >/etc/sudoers.d/90_${USER} <<EOF
${USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/90_${USER}

# 3) Force UTC timezone
timedatectl set-timezone UTC

# 4) Disable sleep/hibernate/power-key
systemctl mask sleep.target suspend.target \
               hibernate.target hybrid-sleep.target
mkdir -p /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/ignore-power.conf <<EOF
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
EOF
systemctl reload systemd-logind

# 5) Weekly APT update via systemd timer
cat >/etc/systemd/system/weekly-apt.service <<EOF
[Unit]
Description=Weekly APT update & upgrade

[Service]
Type=oneshot
TimeoutStartSec=1h
ExecStart=/usr/bin/apt-get update && /usr/bin/apt-get -y upgrade
EOF

cat >/etc/systemd/system/weekly-apt.timer <<EOF
[Unit]
Description=Run weekly APT update & upgrade

[Timer]
OnCalendar=Mon *-*-* 12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now weekly-apt.timer

# 6) Partition, format & mount /dev/sda → /data
if [[ ! -b "${DEVICE}1" ]]; then
  parted -s "$DEVICE" mklabel gpt mkpart primary ext4 0% 100%
  partprobe "$DEVICE"
  sleep 1
  mkfs.ext4 -F "${DEVICE}1"
fi

mkdir -p "$MOUNTPOINT"
UUID=$(blkid -s UUID -o value "${DEVICE}1")
if ! grep -q "UUID=${UUID}" /etc/fstab; then
  echo "UUID=${UUID} ${MOUNTPOINT} ext4 defaults,nofail 0 2" >>/etc/fstab
fi
if ! mountpoint -q "$MOUNTPOINT"; then
  mount "$MOUNTPOINT"
fi

# 7) Snapshot DHCP lease into Netplan static config (with DNS) and fix resolv.conf
NETPLAN_FILE=/etc/netplan/00-installer-config.yaml

if [[ ! -f "$NETPLAN_FILE" ]]; then
  # 1) detect primary interface
  IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

  # 2) grab current IPv4/CIDR, gateway, DNS servers
  ADDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
  GATEWAY=$(ip route | awk '/^default via/ {print $3; exit}')
  # comma‑separated list, e.g. "192.168.1.1,8.8.8.8"
  DNS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd, -)

  # 3) write netplan file with nameservers block
  cat >"$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $ADDR
      nameservers:
        addresses: [${DNS}]
      routes:
        - to: 0.0.0.0/0
          via: $GATEWAY
EOF

  # 4) tighten perms & apply
  chown root:root "$NETPLAN_FILE"
  chmod 0600     "$NETPLAN_FILE"
  netplan apply

  # 5) point resolv.conf at the right file so DNS works
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

  echo "🔒 Static IP + DNS locked: $ADDR on $IFACE (gw: $GATEWAY, dns: $DNS)"
fi

# 8) Show SSH command
echo "=== SSH access ==="
echo "ssh ${USER}@${ADDR}"
echo
