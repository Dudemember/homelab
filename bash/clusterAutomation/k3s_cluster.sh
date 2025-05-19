#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# install_k3s_datadir.sh — fresh k3s install with all data & runtime under MOUNTPOINT
# Usage: ./install_k3s_datadir.sh
# Requires localvars with: USER, MY_SSH_KEY, MOUNTPOINT (e.g. /data), NODES=(...)
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"
: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
: "${MOUNTPOINT:?MOUNTPOINT must be set in localvars (e.g. /data)}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null"

MASTER="${NODES[0]}"

# 1️⃣ Prepare bind‑mounts on every node
for host in "${NODES[@]}"; do
  echo "→ Preparing data‑dir & run‑dir bind on $host"
  ssh $SSH_OPTS "${USER}@${host}" sudo bash -eux <<EOF
mkdir -p ${MOUNTPOINT}/k3s ${MOUNTPOINT}/k3s/run
mkdir -p /var/lib/rancher/k3s /run/k3s

# Persist fstab entries
grep -q "${MOUNTPOINT}/k3s /var/lib/rancher/k3s" /etc/fstab \
  || echo "${MOUNTPOINT}/k3s /var/lib/rancher/k3s none bind 0 0" >> /etc/fstab
grep -q "${MOUNTPOINT}/k3s/run /run/k3s" /etc/fstab \
  || echo "${MOUNTPOINT}/k3s/run /run/k3s none bind 0 0" >> /etc/fstab

# Perform the bind‑mounts now
mountpoint -q /var/lib/rancher/k3s || mount --bind ${MOUNTPOINT}/k3s /var/lib/rancher/k3s
mountpoint -q /run/k3s                || mount --bind ${MOUNTPOINT}/k3s/run /run/k3s
EOF
done

# 2️⃣ Install k3s server on master, pointing at our data-dir
echo "→ Installing k3s server on master ($MASTER)"
ssh $SSH_OPTS "${USER}@${MASTER}" sudo bash -eux <<EOF
export INSTALL_K3S_EXEC="server --data-dir ${MOUNTPOINT}/k3s"
curl -sfL https://get.k3s.io | sh -
EOF

# 3️⃣ Grab and persist the join token
echo "→ Retrieving join token"
TOKEN=\$(ssh $SSH_OPTS "${USER}@${MASTER}" sudo cat "${MOUNTPOINT}/k3s/server/node-token")
echo "   • Token: \$TOKEN"
if grep -q '^K3S_TOKEN=' "$LOCALVARS"; then
  sed -i "s|^K3S_TOKEN=.*|K3S_TOKEN=\"\$TOKEN\"|" "$LOCALVARS"
else
  echo "K3S_TOKEN=\"\$TOKEN\"" >>"$LOCALVARS"
fi
echo "   • K3S_TOKEN written to $LOCALVARS"

# 4️⃣ Install k3s agents on all other nodes
for host in "${NODES[@]:1}"; do
  echo "→ Installing k3s agent on $host"
  ssh $SSH_OPTS "${USER}@${host}" sudo bash -eux <<EOF
export INSTALL_K3S_EXEC="agent --data-dir ${MOUNTPOINT}/k3s"
export K3S_URL="https://${MASTER}:6443"
export K3S_TOKEN="\$TOKEN"
curl -sfL https://get.k3s.io | sh -
EOF
done

# 5️⃣ Final verification
echo "→ Verifying cluster nodes on master"
ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl get nodes

echo "✅ k3s install complete. All state & runtime is now under ${MOUNTPOINT}/k3s."
