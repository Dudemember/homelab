#!/usr/bin/env bash
set -euo pipefail

# ----- Configuration -----
USER=labuser
# The file in the script’s directory that contains ONLY the password for $USER
PASS_FILE="$(dirname "$0")/labuser.pass"
DEVICE=/dev/sda
MOUNTPOINT=/data

# Read password
if [[ ! -s "$PASS_FILE" ]]; then
  echo "ERROR: password file '$PASS_FILE' not found or empty" >&2
  exit 1
fi
PASS="$(< "$PASS_FILE")"

# 1) Install SSH + parted
apt-get update
apt-get install -y openssh-server parted
systemctl enable --now ssh

# 2) labuser + passwordless sudo
if ! id "$USER" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "$USER"
  echo "${USER}:${PASS}" | chpasswd
fi
cat >/etc/sudoers.d/90_${USER} <<EOF
${USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/90_${USER}

# 3) Force UTC timezone
timedatectl set-timezone UTC

# 4) Disable suspend/hibernate/power‑key
systemctl mask sleep.target suspend.target \
               hibernate.target hybrid-sleep.target
mkdir -p /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/ignore-power.conf <<EOF
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
systemctl reload systemd-logind

# 5) Weekly APT update & upgrade via systemd timer
cat >/etc/systemd/system/weekly-apt-upgrade.service <<EOF
[Unit]
Description=Weekly APT update & upgrade

[Service]
Type=oneshot
# Kill the job if it runs longer than 1 hour
TimeoutStartSec=1h
# Make sure we don't try to restart it on failure
Restart=no

ExecStart=/usr/bin/apt-get update
ExecStart=/usr/bin/apt-get -y upgrade
EOF

cat >/etc/systemd/system/weekly-apt-upgrade.timer <<EOF
[Unit]
Description=Run weekly APT update & upgrade

[Timer]
OnCalendar=Mon *-*-* 12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now weekly-apt-upgrade.timer

# 6) idempotent: Partition, format & mount /dev/sda → /data
if [ ! -b "${DEVICE}1" ]; then
  parted -s "$DEVICE" mklabel gpt \
         mkpart primary ext4 0% 100%
  partprobe "$DEVICE"
  sleep 1
  mkfs.ext4 -F "${DEVICE}1"
fi

# ensure mountpoint exists
mkdir -p "$MOUNTPOINT"

# grab UUID
UUID=$(blkid -s UUID -o value "${DEVICE}1")

# add fstab entry if missing
if ! grep -q "UUID=${UUID}" /etc/fstab; then
  cat >>/etc/fstab <<EOF
UUID=${UUID} ${MOUNTPOINT} ext4 defaults,nofail 0 2
EOF
fi

# mount if not already
if ! mountpoint -q "$MOUNTPOINT"; then
  mount "$MOUNTPOINT"
fi

# 7) Set Static IP address
NETPLAN_FILE=/etc/netplan/01-static.yaml

if [[ ! -f "$NETPLAN_FILE" ]]; then
  # detect primary iface
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')

  # grab current IP/CIDR, gateway, and DNS
  ADDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
  GATEWAY=$(ip route | awk '/^default via/ {print $3; exit}')
  DNS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd ',' -)

  # write static config using 'routes:' instead of gateway4
  cat >"$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses: [ $ADDR ]
      routes:
        - to: 0.0.0.0/0
          via: $GATEWAY
      nameservers:
        addresses: [ $DNS ]
EOF

  # lock down permissions and ownership
  chown root:root "$NETPLAN_FILE"
  chmod 0644     "$NETPLAN_FILE"

  # apply immediately
  netplan apply
  echo "🔒 Static IP locked: $ADDR on $IFACE"
fi

echo "✔ Core setup complete:
  • SSH & labuser w/ sudo  
  • UTC timezone  
  • Sleep/hibernate disabled  
  • Weekly apt timer  
  • /dev/sda formatted & mounted at /data
  • Set Static IP adress"

# 8) Show SSH connection command
IP=$(hostname -I | awk '{print $1}')
echo
echo "=== SSH access ==="
echo "ssh ${USER}@${IP}"
echo
