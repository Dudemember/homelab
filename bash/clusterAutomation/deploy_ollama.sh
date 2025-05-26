#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# deploy_ollama.sh — SSH into your k3s master, install Ollama via Helm,
# pull & serve the model defined in OLLAMA_MODEL (localvars), persist it,
# add a readinessProbe, and force‑restart on each run.
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL must be set in localvars (e.g. deepseek-r1:1.5b)}"
(( ${#NODES[@]} > 0 )) || { echo "ERROR: NODES must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-i "$SSH_KEY" \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null)

MASTER="${NODES[0]}"

echo "→ Deploying Ollama (model: $OLLAMA_MODEL) on k3s master: $MASTER"

ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" sudo bash -eux <<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 1️⃣ Add/update the Ollama Helm repo
helm repo add ollama-helm https://otwld.github.io/ollama-helm/ >/dev/null 2>&1 || true
helm repo update

# 2️⃣ Write values with persistence enabled
cat >/tmp/ollama-values.yaml <<VALS
llm:
  models:
    - $OLLAMA_MODEL

persistentVolume:
  enabled: true
  size: "50Gi"
  storageClass: ""
  accessModes:
    - ReadWriteOnce
  subPath: ""
VALS

# 3️⃣ Install or upgrade Ollama, waiting up to 10 minutes for rollout
helm upgrade --install ollama ollama-helm/ollama \
  --namespace ollama --create-namespace \
  --values /tmp/ollama-values.yaml \
  --wait --timeout 10m0s

# 4️⃣ Patch in a readinessProbe so /v1/models must succeed before Ready
kubectl -n ollama patch deployment ollama --type=json -p='[{
  "op": "add",
  "path": "/spec/template/spec/containers/0/readinessProbe",
  "value": {
    "httpGet": {"path":"/v1/models","port":11434},
    "initialDelaySeconds": 5,
    "periodSeconds": 5,
    "timeoutSeconds": 2,
    "failureThreshold": 12
  }
}]'

# 4️⃣.a Force‑restart the Ollama pod so the probe & model config take effect
kubectl -n ollama rollout restart deployment/ollama

# 5️⃣ Wait again for rollout (the readinessProbe gates Ready)
kubectl -n ollama rollout status deploy/ollama --timeout=10m0s
EOF

# 6️⃣ Persist the Ollama service URL in localvars for later use
OLLAMA_URL="http://ollama.ollama.svc.cluster.local:11434"
if grep -q '^OLLAMA_URL=' "$LOCALVARS"; then
  sed -i "s|^OLLAMA_URL=.*|OLLAMA_URL=\"$OLLAMA_URL\"|" "$LOCALVARS"
else
  echo "OLLAMA_URL=\"$OLLAMA_URL\"" >>"$LOCALVARS"
fi

# 7️⃣ Print out endpoint info
echo
echo "✅ Ollama deployed with persistence and model loaded!"
echo "→ Internal endpoint: $OLLAMA_URL"
echo "→ To call chat: POST $OLLAMA_URL/v1/chat/completions"
