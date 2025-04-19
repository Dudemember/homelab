#!/bin/bash

set -euo pipefail

USERNAME="ubuntu"
PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkrekckA8LBPDttJLuITRxAsdu23+MIk0qKTBxPoSri ansible@homelab"

echo "[+] Ensuring user '$USERNAME' exists and is configured for SSH access..."

# Create user if not exists
if ! id "$USERNAME" &>/dev/null; then
  adduser --disabled-password --gecos "" "$USERNAME"
  usermod -aG sudo "$USERNAME"
fi

# Ensure sudo group membership
if ! id "$USERNAME" | grep -q '\bsudo\b'; then
  usermod -aG sudo "$USERNAME"
fi

# Set up .ssh directory and authorized_keys
SSH_DIR="/home/$USERNAME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
touch "$AUTHORIZED_KEYS"

# Ensure pub key is present (append only if not already there)
if ! grep -qxF "$PUB_KEY" "$AUTHORIZED_KEYS"; then
  echo "$PUB_KEY" >> "$AUTHORIZED_KEYS"
fi

# Set correct permissions
chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# Set up passwordless sudo if not already set
SUDOERS_FILE="/etc/sudoers.d/$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

# Harden SSH settings (safely)
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# Full system update (noninteractive)
echo "[+] Performing system upgrade..."
apt update
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
apt autoremove -y
apt clean

echo "[✓] Node is configured and safe to re-run anytime."
