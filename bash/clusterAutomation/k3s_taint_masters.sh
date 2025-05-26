#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# k3s_taint_masters.sh — Taint or untaint the k3s master node based on
# K3S_TAINT_MASTERS in localvars. Automatically picks the first Kubernetes node
# from 'kubectl get nodes'. When tainting, it also drains everything except
# Dashboard (which must tolerate the master taint), then verifies no stray pods.
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
: "${K3S_TAINT_MASTERS:?K3S_TAINT_MASTERS must be set to true or false in localvars}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null"

MASTER="${NODES[0]}"

echo "→ Connecting to master node: $MASTER"

# 1️⃣ Figure out the real node name
NODE_NAME=$(ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl \
  get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -n1)

if [[ -z "$NODE_NAME" ]]; then
  echo "ERROR: Could not retrieve any node names from 'kubectl get nodes'." >&2
  exit 1
fi

echo "→ Kubernetes node name: $NODE_NAME"
echo "→ Desired taint state: $K3S_TAINT_MASTERS"

# 2️⃣ Taint + Drain + Verify or Untaint
if [[ "$K3S_TAINT_MASTERS" == "true" ]]; then
  echo "→ Tainting master ($NODE_NAME) with NoSchedule"
  ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl taint nodes \
    "$NODE_NAME" node-role.kubernetes.io/master:NoSchedule --overwrite

  echo "→ Draining master ($NODE_NAME): evicting everything except Dashboard"
  ssh $SSH_OPTS "${USER}@${MASTER}" sudo bash -eux <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=30 \
  --timeout=120s

# ──────────────────────────────────────────────────────────────────────────────
# Verify no stray pods except system DaemonSets and Dashboard
echo "→ Verifying no stray pods on $NODE_NAME…"
kubectl get pods --all-namespaces --field-selector spec.nodeName="$NODE_NAME" \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name \
  | grep -Ev '^(kube-system|kubernetes-dashboard)\\b' \
  && { echo "ERROR: Found non‑system/dashboard pods on master!"; exit 1; } \
  || echo "✓ Only system DaemonSets and Dashboard remain."
EOF

elif [[ "$K3S_TAINT_MASTERS" == "false" ]]; then
  echo "→ Checking for any NoSchedule taint on $NODE_NAME…"
  ssh $SSH_OPTS "${USER}@${MASTER}" sudo bash -eux <<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Find any taint with effect=NoSchedule
taint_key=\$(kubectl get node "$NODE_NAME" \
  -o jsonpath='{.spec.taints[?(@.effect=="NoSchedule")].key}' 2>/dev/null || true)

if [[ -n "\$taint_key" ]]; then
  echo "→ Removing taint \$taint_key:NoSchedule from $NODE_NAME"
  kubectl taint nodes "$NODE_NAME" "\$taint_key":NoSchedule- 2>/dev/null || true
else
  echo "→ No NoSchedule taints found; nothing to remove."
fi
EOF

else
  echo "ERROR: K3S_TAINT_MASTERS must be 'true' or 'false'." >&2
  exit 1
fi

echo "✅ Taint/drain operation complete on $NODE_NAME"
