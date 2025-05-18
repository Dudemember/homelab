#!/usr/bin/env bash
set -euo pipefail

USER=labuser
PASS='CHANGE_ME'    # ←change this before running

# 1. SSH server
apt-get update
apt-get install -y openssh-server
systemctl enable --now ssh

# 2. labuser + sudo
if ! id "$USER" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "$USER"
  echo "${USER}:${PASS}" | chpasswd
fi
cat >/etc/sudoers.d/90_${USER} <<EOF
${USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/90_${USER}

# 3. Force UTC timezone
timedatectl set-timezone UTC

# 4. Disable all sleep/hibernate/power-key actions
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

# 5. Weekly APT upgrade via systemd timer
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

echo "✔ setup complete:
  • SSH enabled
  • user '$USER' with passwordless sudo
  • timezone UTC
  • sleep/hibernate/power-key disabled
  • weekly apt update & upgrade (Mon 12:00 UTC)"
