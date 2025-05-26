#!/usr/bin/env bash
set -euo pipefail

# Path to your localvars file
LOCALVARS=./localvars
if [[ ! -r $LOCALVARS ]]; then
  echo "ERROR: cannot read $LOCALVARS" >&2
  exit 1
fi
# Load variables (USER, NODES[], PASS_FILE, MY_SSH_KEY, MY_SSH_KEY_OVERWRITE)
# shellcheck disable=SC1090
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${PASS_FILE:?PASS_FILE must be set in localvars}"
if [[ ! -r $PASS_FILE ]]; then
  echo "ERROR: cannot read PASS_FILE ($PASS_FILE)" >&2
  exit 1
fi
# Read password into memory
PASS="$(<"$PASS_FILE")"

# Validate NODES array
if ! declare -p NODES &>/dev/null; then
  echo "ERROR: NODES array must be defined in localvars" >&2
  exit 1
fi
if (( ${#NODES[@]} == 0 )); then
  echo "ERROR: NODES array must contain at least one element" >&2
  exit 1
fi

# 1) Determine SSH key path up front
if [[ -n "${MY_SSH_KEY:-}" ]]; then
  # Expand leading '~'
  KEY_PATH="${MY_SSH_KEY/#\~/$HOME}"
  echo "✔ Using existing MY_SSH_KEY from localvars: $MY_SSH_KEY"
else
  # Remove any existing MY_SSH_KEY entries and set a default
  sed -i '/^MY_SSH_KEY=/d' "$LOCALVARS"
  printf "\nMY_SSH_KEY=\"~/.ssh/${USER}_ed25519\"\n" >> "$LOCALVARS"
  KEY_PATH="$HOME/.ssh/${USER}_ed25519"
  echo "🔧 Set MY_SSH_KEY=\"~/.ssh/${USER}_ed25519\" in localvars"
fi
PUB_PATH="$KEY_PATH.pub"

# 2) Handle overwrite flag
FORCE="${MY_SSH_KEY_OVERWRITE:-false}"
if [[ $FORCE == true ]]; then
  echo "⚠️  MY_SSH_KEY_OVERWRITE=true: removing old key files"
  rm -f "$KEY_PATH" "$PUB_PATH"

  # Change the existing setting to false, or add it if missing
  if grep -q '^MY_SSH_KEY_OVERWRITE=' "$LOCALVARS"; then
    sed -i 's|^MY_SSH_KEY_OVERWRITE=.*|MY_SSH_KEY_OVERWRITE=false|' "$LOCALVARS"
  else
    printf "\nMY_SSH_KEY_OVERWRITE=false\n" >> "$LOCALVARS"
  fi
fi

# 3) Generate key if missing
if [[ ! -f "$KEY_PATH" ]]; then
  echo "🔑 Generating new ed25519 keypair at $KEY_PATH (no passphrase)…"
  mkdir -p "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -C "${USER}@home-lab" -N ""
else
  echo "✔ SSH key exists at $KEY_PATH"
fi

# 4) Create SSH_ASKPASS helper
ASKPASS=$(mktemp)
chmod +x "$ASKPASS"
cat >"$ASKPASS" <<EOF
#!/usr/bin/env sh
echo "$PASS"
EOF

# 5) Distribute to each node
echo "🔄 Distributing public key to each node…"
for host in "${NODES[@]}"; do
  printf " → %s: " "$host"
  # Try key-based auth first
  if ssh -i "$KEY_PATH" \
         -o BatchMode=yes \
         -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
       "$USER@$host" true &>/dev/null; then
    echo "already installed"
  else
    # Use SSH_ASKPASS with setsid to feed password non-interactively
    DISPLAY=none SSH_ASKPASS="$ASKPASS" \
      setsid ssh-copy-id -i "$PUB_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$USER@$host" \
        </dev/null &>/dev/null \
      && echo "installed" || echo "FAILED"
  fi
done

# 6) Cleanup
rm -f "$ASKPASS"


echo "✅ Done. Next time, SSH with:"
echo "   ssh -i \"$KEY_PATH\" $USER@<node-ip>"
