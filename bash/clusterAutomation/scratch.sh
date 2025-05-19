#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# patch_dashboard_nodeport.sh — SSH into the k3s master and patch the Dashboard
# proxy Service to NodePort=30080 so it’s reachable externally.
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES must be set in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

MASTER="${NODES[0]}"

echo "→ Patching Dashboard proxy Service on master: $MASTER"
ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" sudo bash -eux <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Patch the proxy Service to NodePort on 30080
kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard-kong-proxy \
  --type='json' \
  -p='[
    {"op":"replace","path":"/spec/type","value":"NodePort"},
    {"op":"add","path":"/spec/ports/0/nodePort","value":30080}
  ]'
EOF

echo "✅ kubernetes-dashboard-kong-proxy is now NodePort 30080"
