#!/usr/bin/env bash
set -euo pipefail

USER=labuser
PASS='CHANGE_ME'    # ← set before running
DEVICE=/dev/sda
MOUNTPOINT=/data

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
systemctl restart systemd-logind

# 5) Weekly APT via systemd timer
cat >/etc/systemd/system/weekly-apt-upgrade.service <<EOF
[Unit]
Description=Weekly APT update & upgrade

[Service]
Type=oneshot
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

# 6) Partition, format & mount /dev/sda → /data
parted -s "$DEVICE" mklabel gpt \
       mkpart primary ext4 0% 100%
partprobe "$DEVICE"
sleep 1
mkfs.ext4 -F "${DEVICE}1"
mkdir -p "$MOUNTPOINT"
UUID=$(blkid -s UUID -o value "${DEVICE}1")
grep -q "$UUID" /etc/fstab || cat >>/etc/fstab <<EOF
UUID=${UUID} ${MOUNTPOINT} ext4 defaults,nofail 0 2
EOF
mount "$MOUNTPOINT"

echo "✔ core setup complete:
  • SSH & labuser w/ sudo  
  • UTC timezone  
  • Sleep/hibernate disabled  
  • Weekly apt timer  
  • /dev/sda formatted & mounted at /data

Next: install Kubernetes & container runtime, then add bind‑mounts for /var/lib/containerd and /var/lib/kubelet off /data."
