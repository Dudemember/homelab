#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# deploy_dify.sh — SSH into your k3s master, install/upgrade Dify via Helm,
# ensure clean proxy Service, expose on a configurable NodePort, restart it if
# already running, and persist & print the UI URL.
# ------------------------------------------------------------------------------

# 0️⃣ Load & validate localvars
LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
dos2unix "$LOCALVARS" >/dev/null 2>&1 || true
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
: "${OLLAMA_URL:?OLLAMA_URL must be set in localvars}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

# 0.1️⃣ Pick your NodePort (defaults to 30081)
DIFY_NODE_PORT="${DIFY_NODE_PORT:-30081}"

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
MASTER="${NODES[0]}"

echo "→ Deploying Dify on k3s master: $MASTER"
echo "  • Ollama endpoint: $OLLAMA_URL"
echo "  • Exposing UI on NodePort $DIFY_NODE_PORT → port 3000"

ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" sudo bash -eux <<REMOTE_EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=chatbot

# 1) Ensure namespace exists
kubectl create namespace \$NS --dry-run=client -o yaml | kubectl apply -f -

# 2) Delete any old Dify proxy Service
kubectl -n \$NS delete svc my-chatbot-proxy --ignore-not-found

# 3) Add & update the Dify chart repo
helm repo add dify https://borispolonsky.github.io/dify-helm >/dev/null 2>&1 || true
helm repo update

# 4) Build our values file (Ollama URL & NodePort embedded)
cat >/tmp/dify-values.yaml <<VALS
modelProviders:
  - name: LocalDeepSeek
    type: http
    endpoint: "${OLLAMA_URL}/api/generate"
    request:
      model: "${OLLAMA_MODEL:-deepseek-r1:1.5b}"
      prompt: "{{ input }}"
      max_tokens: 512
    responsePath: "\$.choices[0].text"

proxy:
  service:
    type: NodePort
    nodePort: ${DIFY_NODE_PORT}
    port: 3000
VALS

# 5) Install or upgrade Dify
helm upgrade --install my-chatbot dify/dify \
  --namespace \$NS --create-namespace \
  --values /tmp/dify-values.yaml

# 6) Discover service & deployment names
SVC_NAME=\$(kubectl -n \$NS get svc \
  -l app.kubernetes.io/instance=my-chatbot,component=proxy \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
DEPLOY_NAME=\$(kubectl -n \$NS get deploy \
  -l app.kubernetes.io/instance=my-chatbot,component=proxy \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

# 7) Patch Service to enforce NodePort
if [[ -n "\$SVC_NAME" ]]; then
  kubectl -n \$NS patch svc "\$SVC_NAME" --type merge -p '{
    "spec":{
      "type":"NodePort",
      "ports":[{
        "name":"http",
        "port":3000,
        "targetPort":3000,
        "nodePort":'"${DIFY_NODE_PORT}"',
        "protocol":"TCP"
      }]
    }
  }'
else
  echo "WARNING: proxy Service not found; skipping patch"
fi

# 8) Restart & wait on the proxy deployment
if [[ -n "\$DEPLOY_NAME" ]]; then
  kubectl -n \$NS rollout restart deploy/"\$DEPLOY_NAME"
  kubectl -n \$NS rollout status deploy/"\$DEPLOY_NAME" --timeout=5m
else
  echo "WARNING: proxy Deployment not found; skipping restart/wait"
fi
REMOTE_EOF

# 9️⃣ Persist the UI URL
DIFY_URL="https://${MASTER}:${DIFY_NODE_PORT}"
if grep -q '^DIFY_URL=' "$LOCALVARS"; then
  sed -i "s|^DIFY_URL=.*|DIFY_URL=\"$DIFY_URL\"|" "$LOCALVARS"
else
  echo "DIFY_URL=\"$DIFY_URL\"" >>"$LOCALVARS"
fi

# 🔟 Print it one more time so it *can’t* be missed
echo
echo "✅ Dify UI → $DIFY_URL"
echo

