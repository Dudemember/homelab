#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# refresh_dashboard_token.sh — SSH into k3s master, create a 24h Dashboard token,
# persist it as K8S_DASHBOARD_TOKEN in localvars, and echo it.
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
[[ "${#NODES[@]}" -gt 0 ]]   || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }
MASTER="${NODES[0]}"

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null"

echo "→ Creating new 24h Dashboard token on $MASTER…"
NEW_TOKEN=$(ssh $SSH_OPTS "${USER}@${MASTER}" sudo k3s kubectl \
  -n kubernetes-dashboard create token dashboard-admin-sa --duration=24h)

echo "   • Token: $NEW_TOKEN"

# Persist into localvars
if grep -q '^K8S_DASHBOARD_TOKEN=' "$LOCALVARS"; then
  sed -i "s|^K8S_DASHBOARD_TOKEN=.*|K8S_DASHBOARD_TOKEN=\"$NEW_TOKEN\"|" "$LOCALVARS"
else
  echo "K8S_DASHBOARD_TOKEN=\"$NEW_TOKEN\"" >>"$LOCALVARS"
fi

echo "   • Updated K8S_DASHBOARD_TOKEN in $LOCALVARS"
echo
echo "✅ Your new Dashboard token (valid 24h) is in K8S_DASHBOARD_TOKEN."
