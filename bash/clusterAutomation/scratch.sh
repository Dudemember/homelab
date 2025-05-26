#!/usr/bin/env bash
set -euo pipefail

# ─── Load your localvars ──────────────────────────────────────────────────────
LOCALVARS="./localvars"
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

# ─── Ensure we’re running under Bash ──────────────────────────────────────────
if [ -z "${BASH_VERSION-}" ]; then
  echo "ERROR: please run this script with Bash, not sh" >&2
  exit 1
fi

# ─── Sanity checks ────────────────────────────────────────────────────────────
: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
(( ${#NODES[@]} > 0 ))   || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }
: "${OLLAMA_NAMESPACE:?OLLAMA_NAMESPACE must be set in localvars}"
: "${OLLAMA_URL:?OLLAMA_URL must be set in localvars}"

# ─── SSH config & master ──────────────────────────────────────────────────────
SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
MASTER="${NODES[0]}"

echo ">>> Running diagnostics on master: $MASTER"
echo

ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" bash <<EOF
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 1) Locate the Gradio pod
POD=\$(sudo k3s kubectl get pods -n "${OLLAMA_NAMESPACE}" \
      -l app=gradio-chat-ui \
      -o jsonpath='{.items[0].metadata.name}')
echo "→ Using pod: \$POD"

# 2) Tail its logs
echo "---- Last 200 lines from \$POD logs ----"
sudo k3s kubectl logs -n "${OLLAMA_NAMESPACE}" "\$POD" --tail=200

# 3) Curl Ollama /v1/models from inside the pod
echo
echo "---- Curl /v1/models from inside pod ----"
sudo k3s kubectl exec -n "${OLLAMA_NAMESPACE}" "\$POD" -- \
  curl -v "${OLLAMA_URL}/v1/models"
EOF
