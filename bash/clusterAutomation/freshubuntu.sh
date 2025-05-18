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

# 7) Freeze current DHCP lease as a manual NM connection
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
CONN=$(nmcli -t -f NAME,DEVICE connection show --active \
       | awk -F: -v iface="$IFACE" '$2==iface{print $1; exit}')
if [[ -z "$CONN" ]]; then
  # fallback to first ethernet profile
  CONN=$(nmcli -t -f NAME,TYPE connection show \
         | awk -F: '$2=="ethernet"{print $1; exit}')
fi

if [[ "$(nmcli -g ipv4.method connection show "$CONN")" != manual ]]; then
  IFS=$'\n' read -r IP GW DNS <<<"$(nmcli -g ipv4.addresses,ipv4.gateway,ipv4.dns connection show "$CONN")"
  nmcli connection modify "$CONN" \
    ipv4.method manual \
    ipv4.addresses "$IP" \
    ipv4.gateway   "$GW" \
    ipv4.dns       "$DNS" \
    connection.autoconnect yes
  nmcli connection up "$CONN"
  echo "🔒 Locked $CONN to manual IP $IP (gw: $GW, dns: $DNS)"
else
  IP=$(nmcli -g ipv4.addresses connection show "$CONN")
  echo "✔ $CONN already manual at $IP"
fi

# 8) Show SSH connection command
echo
echo "=== SSH access ==="
echo "ssh ${USER}@${IP}"
echo
