#!/usr/bin/env bash
set -euo pipefail

# 1) load your localvars (must define USER, NODES array, and PASS_FILE if you want to verify it)
LOCALVARS="./localvars"
if [[ ! -r $LOCALVARS ]]; then
  echo "ERROR: cannot read $LOCALVARS" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${#NODES[@]:?NODES array must be defined and non-empty in localvars}"

# 2) define key paths
KEY="$HOME/.ssh/${USER}_ed25519"
PUB="$KEY.pub"

# 3) generate key if needed
if [[ -f "$KEY" ]]; then
  echo "✔️  Using existing key: $KEY"
else
  echo "🔑 Generating new ed25519 keypair at $KEY (no passphrase)…"
  ssh-keygen -t ed25519 -f "$KEY" -C "${USER}@home-lab" -N ""
fi

# 4) distribute to each node
echo
echo "🔄 Copying public key to each node (you’ll be prompted for the password one last time)…"
for host in "${NODES[@]}"; do
  printf " → %s: " "$host"
  # ssh-copy-id will ask you for the password interactively
  ssh-copy-id -i "$PUB" -o StrictHostKeyChecking=no "$USER@$host"
done

echo
echo "✅ All done. You can now SSH into any node without a password:"
echo "   ssh -i $KEY $USER@<node-ip>"
