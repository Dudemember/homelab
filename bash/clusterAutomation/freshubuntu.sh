#!/bin/bash

set -e

USERNAME="ubuntu"
PUB_KEY="ssh-ed25519 AAAAC3NzA...tMvmQ== ansible@homelab"

echo "[+] Creating user '$USERNAME' and configuring SSH..."

# Create user if not exists
if ! id "$USERNAME" &>/dev/null; then
  adduser --disabled-password --gecos "" "$USERNAME"
  usermod -aG sudo "$USERNAME"
fi

# Setup SSH
mkdir -p /home/$USERNAME/.ssh
echo "$PUB_KEY" > /home/$USERNAME/.ssh/authorized_keys
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chmod 700 /home/$USERNAME/.ssh
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# Passwordless sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME

# Harden SSH (optional)
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

echo "[+] Updating OS packages (full-upgrade)..."

# OS Updates
apt update
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
apt autoremove -y
apt clean

echo "[✓] Node is ready for Ansible use!"
