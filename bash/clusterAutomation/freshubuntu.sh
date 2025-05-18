#!/usr/bin/env bash
set -euo pipefail

# ----- Configuration -----
USER=labuser
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
TimeoutStartSec=1h
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

mkdir -p "$MOUNTPOINT"
UUID=$(blkid -s UUID -o value "${DEVICE}1")
if ! grep -q "UUID=${UUID}" /etc/fstab; then
  cat >>/etc/fstab <<EOF
UUID=${UUID} ${MOUNTPOINT} ext4 defaults,nofail 0 2
EOF
fi
if ! mountpoint -q "$MOUNTPOINT"; then
  mount "$MOUNTPOINT"
fi

# 7) Convert current DHCP lease into a manual NM connection
#    (runs only once; safe to re-run)
if ! nmcli -t -f ipv4.method connection show | grep -q manual; then
  apt-get install -y network-manager
  systemctl enable --now NetworkManager

  # detect primary interface and its active connection
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
  CONN=$(nmcli -t -f NAME,DEVICE connection show --active \
         | awk -F: -v if="$IFACE" '$2==if{print $1; exit}')

  # fallback to the first ethernet profile if none active
  if [[ -z "$CONN" ]]; then
    CONN=$(nmcli -t -f NAME,TYPE connection show \
           | awk -F: '$2=="ethernet"{print $1; exit}')
  fi

  # grab current lease info
  ADDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
  GATEWAY=$(ip route | awk '/^default via/ {print $3; exit}')
  DNS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd" " -)

  # apply manual settings
  nmcli connection modify "$CONN" \
    ipv4.method manual \
    ipv4.addresses "$ADDR" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS" \
    connection.autoconnect yes

  nmcli connection up "$CONN"
  echo "🔒 NM manual IP locked: $ADDR on $IFACE"
fi

echo "✔ Core setup complete:
  • SSH & labuser w/ sudo  
  • UTC timezone  
  • Sleep/hibernate disabled  
  • Weekly apt timer  
  • /dev/sda formatted & mounted at /data  
  • Wired connection set to manual with current IP"

# 8) Show SSH connection command
IP=$(hostname -I | awk '{print $1}')
echo
echo "=== SSH access ==="
echo "ssh ${USER}@${IP}"
echo
