#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# install_dashboard_nodeport.sh — uninstall & install Kubernetes Dashboard on
# the k3s master, expose its Kong proxy as NodePort 30080, force fresh images,
# restart pods, wait for readiness, and persist the login token to localvars.
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null"

MASTER="${NODES[0]}"

echo "→ Uninstalling any existing Dashboard release on master: $MASTER"
ssh $SSH_OPTS "${USER}@${MASTER}" sudo bash -eux <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 1) Remove existing release (ignore errors if none)
helm uninstall kubernetes-dashboard --namespace kubernetes-dashboard || true

# 2) (Optional) purge namespace entirely for a clean slate
# kubectl delete ns kubernetes-dashboard --wait || true

# 3) Add/update the official Dashboard Helm repo
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ >/dev/null 2>&1 || true
helm repo update

# 4) Fresh install with NodePort & tolerations & Always pull images
helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard --create-namespace \
  --set proxy.service.type=NodePort \
  --set proxy.service.nodePort=30080 \
  --set image.pullPolicy=Always \
  --set tolerations[0].key="node-role.kubernetes.io/master" \
  --set tolerations[0].operator="Exists" \
  --set tolerations[0].effect="NoSchedule"

# 5) Patch the kong‑proxy Service to ensure NodePort 30080
kubectl patch svc kubernetes-dashboard-kong-proxy -n kubernetes-dashboard \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":443,"nodePort":30080}]}}'

# 6) Restart & wait for readiness of every Dashboard deployment
for dep in $(kubectl -n kubernetes-dashboard get deployment -o name | grep -i dashboard); do
  echo "→ Restarting $dep"
  kubectl -n kubernetes-dashboard rollout restart "$dep"
done

for dep in $(kubectl -n kubernetes-dashboard get deployment -o name | grep -i dashboard); do
  echo "→ Waiting on $dep"
  kubectl -n kubernetes-dashboard rollout status "$dep" --timeout=2m
done

# 7) Ensure admin SA & ClusterRoleBinding exist
kubectl -n kubernetes-dashboard get sa dashboard-admin-sa >/dev/null 2>&1 || \
  kubectl -n kubernetes-dashboard create sa dashboard-admin-sa

kubectl get clusterrolebinding dashboard-admin-sa >/dev/null 2>&1 || \
  kubectl create clusterrolebinding dashboard-admin-sa \
    --clusterrole=cluster-admin \
    --serviceaccount=kubernetes-dashboard:dashboard-admin-sa
EOF

echo "→ Retrieving Dashboard login token"
K8S_DASHBOARD_TOKEN=$(ssh $SSH_OPTS "${USER}@${MASTER}" \
  "sudo k3s kubectl -n kubernetes-dashboard create token dashboard-admin-sa")
echo "   • Token: $K8S_DASHBOARD_TOKEN"

# Persist token to localvars
if grep -q '^K8S_DASHBOARD_TOKEN=' "$LOCALVARS"; then
  sed -i "s|^K8S_DASHBOARD_TOKEN=.*|K8S_DASHBOARD_TOKEN=\"$K8S_DASHBOARD_TOKEN\"|" "$LOCALVARS"
else
  echo "K8S_DASHBOARD_TOKEN=\"$K8S_DASHBOARD_TOKEN\"" >>"$LOCALVARS"
fi
echo "   • K8S_DASHBOARD_TOKEN written to $LOCALVARS"

echo
echo "✅ Dashboard is now exposed at https://$MASTER:30080/"
echo "   (self‑signed cert — accept the warning or use: curl -k https://$MASTER:30080/)"
echo "   Use K8S_DASHBOARD_TOKEN from localvars to log in."
