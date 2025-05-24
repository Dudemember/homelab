#!/usr/bin/env bash
set -euo pipefail

# ----- Configuration ----- also in localvars for reference
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

# 1) Install & enable core services
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

# 4) Disable suspend/hibernate/power-key
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
ExecStart=/usr/bin/apt-get update -qq && /usr/bin/apt-get -y upgrade
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
  partprobe "$DEVICE"; sleep 1
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

# 7) Detect interface
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# 8) Gather IP/prefix, gateway, and up to two DNS servers
read -r ADDR PREFIX GATEWAY DNS1 DNS2 < <(
  # addr & prefix
  ip -4 -o addr show dev "$IFACE" | awk '{split($4,a,"/"); print a[1], a[2]; exit}'
  # gateway
  ip route | awk '/^default via/ {print $3; exit}'
  # nameservers (if any) from existing resolv.conf
  awk '/^nameserver/ {print $2}' /etc/resolv.conf | head -n2
)

# 9) Write a static netplan file
cat >/etc/netplan/00-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses:
        - ${ADDR}/${PREFIX}
      nameservers:
        addresses:
EOF
[[ -n "$DNS1" ]] && echo "          - ${DNS1}" >>/etc/netplan/00-static.yaml
[[ -n "$DNS2" ]] && echo "          - ${DNS2}" >>/etc/netplan/00-static.yaml
cat >>/etc/netplan/00-static.yaml <<EOF
      routes:
        - to: default
          via: ${GATEWAY}
EOF

chown root:root /etc/netplan/00-static.yaml
chmod 0600     /etc/netplan/00-static.yaml
netplan apply

# 10) Enable & start systemd-resolved, point resolv.conf to its stub
systemctl enable --now systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 11) Verify DNS is assigned
if ! resolvectl status "$IFACE" | grep -q "DNS Servers"; then
  echo "ERROR: DNS not configured on $IFACE" >&2
  resolvectl status
  exit 1
fi

# 12) Final upgrades & SSH info
apt-get update
apt-get upgrade -y

echo
echo "=== SSH access ==="
echo "ssh ${USER}@${ADDR}"
echo
