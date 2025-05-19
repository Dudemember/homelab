#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# install_dashboard_nodeport.sh — install Kubernetes Dashboard via Helm on k3s master,
# expose it on NodePort 30080 at install time, and persist the login token as
# K8S_DASHBOARD_TOKEN in localvars. No post‑install patching needed.
# ------------------------------------------------------------------------------

# 0️⃣ Load & validate localvars (must define USER, MY_SSH_KEY, NODES=(...))
LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"
: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

MASTER="${NODES[0]}"

echo "→ Installing Kubernetes Dashboard via Helm on master: $MASTER"
ssh $SSH_OPTS "${USER}@${MASTER}" sudo bash -eux <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Add & update the Helm repo
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ >/dev/null 2>&1 || true
helm repo update

# Install or upgrade the Dashboard chart with NodePort settings baked in
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard --create-namespace \
  --set service.type=NodePort \
  --set service.nodePort=30080

# Ensure ServiceAccount & ClusterRoleBinding exist
kubectl -n kubernetes-dashboard get sa dashboard-admin-sa >/dev/null 2>&1 || \
  kubectl -n kubernetes-dashboard create sa dashboard-admin-sa
kubectl get clusterrolebinding dashboard-admin-sa >/dev/null 2>&1 || \
  kubectl create clusterrolebinding dashboard-admin-sa \
    --clusterrole=cluster-admin \
    --serviceaccount=kubernetes-dashboard:dashboard-admin-sa
EOF

# 1️⃣ Retrieve the login token using sudo k3s kubectl
echo "→ Retrieving Dashboard login token"
K8S_DASHBOARD_TOKEN=$(ssh $SSH_OPTS "${USER}@${MASTER}" \
  "sudo k3s kubectl -n kubernetes-dashboard create token dashboard-admin-sa")
echo "   • Token: $K8S_DASHBOARD_TOKEN"

# 2️⃣ Persist token into localvars
if grep -q '^K8S_DASHBOARD_TOKEN=' "$LOCALVARS"; then
  sed -i "s|^K8S_DASHBOARD_TOKEN=.*|K8S_DASHBOARD_TOKEN=\"$K8S_DASHBOARD_TOKEN\"|" "$LOCALVARS"
else
  echo "K8S_DASHBOARD_TOKEN=\"$K8S_DASHBOARD_TOKEN\"" >>"$LOCALVARS"
fi
echo "   • K8S_DASHBOARD_TOKEN written to $LOCALVARS"

# 3️⃣ Print access info
echo
echo "✅ Kubernetes Dashboard installed via Helm on $MASTER"
echo "→ Access it in your browser at:"
echo "     https://$MASTER:30080/"
echo
echo "Use the token stored in localvars (K8S_DASHBOARD_TOKEN) to log in."
