#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# k3s_taint_masters.sh — Taint or untaint the k3s master node based on
# K3S_TAINT_MASTERS in localvars. Automatically picks the first Kubernetes node
# from 'kubectl get nodes' rather than relying on labels.
# ------------------------------------------------------------------------------

# 0️⃣ Load & validate localvars (must define USER, MY_SSH_KEY, NODES=(...), K3S_TAINT_MASTERS)
LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
: "${K3S_TAINT_MASTERS:?K3S_TAINT_MASTERS must be set to true or false in localvars}"
[[ "${#NODES[@]}" -gt 0 ]]   || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

MASTER="${NODES[0]}"

echo "→ Connecting to master node: $MASTER"

# 1️⃣ Determine the Kubernetes node name by taking the first line of `kubectl get nodes`
NODE_NAME=$(ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl \
  get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -n1)

if [[ -z "$NODE_NAME" ]]; then
  echo "ERROR: Could not retrieve any node names from 'kubectl get nodes'." >&2
  exit 1
fi

echo "→ Kubernetes node name: $NODE_NAME"
echo "→ Desired taint state (K3S_TAINT_MASTERS): $K3S_TAINT_MASTERS"

# 2️⃣ Apply or remove the NoSchedule taint
if [[ "$K3S_TAINT_MASTERS" == "true" ]]; then
  echo "→ Tainting master ($NODE_NAME) with NoSchedule"
  ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl taint nodes \
    "$NODE_NAME" node-role.kubernetes.io/master:NoSchedule --overwrite
elif [[ "$K3S_TAINT_MASTERS" == "false" ]]; then
  echo "→ Removing NoSchedule taint from master ($NODE_NAME)"
  ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl taint nodes \
    "$NODE_NAME" node-role.kubernetes.io/master:NoSchedule- || true
else
  echo "ERROR: K3S_TAINT_MASTERS must be 'true' or 'false'." >&2
  exit 1
fi

echo "✅ Taint operation complete on $NODE_NAME"
