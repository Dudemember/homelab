#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# install_dashboard_nodeport.sh — install/upgrade Kubernetes Dashboard via Helm on k3s master,
# expose the UI proxy on NodePort 30080, and persist the login token as K8S_DASHBOARD_TOKEN.
# ------------------------------------------------------------------------------

# 0️⃣ Load & validate localvars
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

echo "→ Installing/Upgrading Kubernetes Dashboard on $MASTER"
ssh $SSH_OPTS "${USER}@${MASTER}" sudo bash -eux <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=kubernetes-dashboard

# 1) Ensure namespace exists
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

# 2) Delete old proxy Service
kubectl -n $NS delete svc kubernetes-dashboard-kong-proxy --ignore-not-found

# 3) Helm upgrade/install with proxy.service.* flags
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ >/dev/null 2>&1 || true
helm repo update
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace $NS \
  --set proxy.service.type=NodePort \
  --set proxy.service.nodePort=30080

# 4) Safety‑net patch in case it didn’t stick
kubectl -n $NS patch svc kubernetes-dashboard-kong-proxy --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8443,"nodePort":30080,"protocol":"TCP","name":"https"}]}}'

# 5) Ensure ServiceAccount & ClusterRoleBinding
kubectl -n $NS get sa dashboard-admin-sa >/dev/null 2>&1 || \
  kubectl -n $NS create sa dashboard-admin-sa
kubectl get clusterrolebinding dashboard-admin-sa >/dev/null 2>&1 || \
  kubectl create clusterrolebinding dashboard-admin-sa \
    --clusterrole=cluster-admin \
    --serviceaccount=$NS:dashboard-admin-sa
EOF

# ──────────────────────────────────────────────────────────────────────────────

# 6️⃣ Retrieve and persist the login token
echo "→ Retrieving Dashboard login token"
K8S_DASHBOARD_TOKEN=$(ssh $SSH_OPTS "${USER}@${MASTER}" \
  "sudo k3s kubectl -n kubernetes-dashboard create token dashboard-admin-sa")
echo "   • Token: $K8S_DASHBOARD_TOKEN"

if grep -q '^K8S_DASHBOARD_TOKEN=' "$LOCALVARS"; then
  sed -i "s|^K8S_DASHBOARD_TOKEN=.*|K8S_DASHBOARD_TOKEN=\"$K8S_DASHBOARD_TOKEN\"|" "$LOCALVARS"
else
  echo "K8S_DASHBOARD_TOKEN=\"$K8S_DASHBOARD_TOKEN\"" >>"$LOCALVARS"
fi
echo "   • Token written to $LOCALVARS"

# 7️⃣ Final info
cat <<INFO

✅ Dashboard is exposed on NodePort 30080.
→ Browse to: https://$MASTER:30080/  (accept the self‑signed cert)
→ Log in with the token in K8S_DASHBOARD_TOKEN.

INFO
