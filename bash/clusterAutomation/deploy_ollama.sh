#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# deploy_ollama.sh — SSH into your k3s master, install Ollama via Helm,
# pull & serve the model defined in OLLAMA_MODEL (localvars), on a
# PersistentVolume so the model stays on restart.
# ------------------------------------------------------------------------------

LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL must be set in localvars (e.g. deepseek-r1:1.5b)}"
[[ "${#NODES[@]}" -gt 0 ]]   || { echo "ERROR: NODES must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

MASTER="${NODES[0]}"

echo "→ Deploying Ollama (model: $OLLAMA_MODEL) on k3s master: $MASTER"

ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" sudo bash -eux <<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 1️⃣ Add & update the Ollama Helm repo
helm repo add ollama-helm https://otwld.github.io/ollama-helm/ >/dev/null 2>&1 || true
helm repo update

# 2️⃣ Write values with persistence enabled
cat >/tmp/ollama-values.yaml <<VALS
llm:
  models:
    - $OLLAMA_MODEL

# persist the model data so it's not lost on pod restart
persistentVolume:
  enabled: true                # turn on PersistentVolumeClaim :contentReference[oaicite:2]{index=2}
  size: "50Gi"                 # allocate 50 GiB for models
  storageClass: ""             # use default StorageClass
  accessModes:
    - ReadWriteOnce            # standard single‑writer mode
  subPath: ""                  # mount at root of the claim
VALS

# 3️⃣ Install or upgrade Ollama, waiting up to 10 minutes for rollout
helm upgrade --install ollama ollama-helm/ollama \
  --namespace ollama --create-namespace \
  --values /tmp/ollama-values.yaml \
  --wait --timeout 10m0s

# 4️⃣ Double‑check deployment status
kubectl -n ollama rollout status deploy/ollama --timeout=10m0s
EOF

# 5️⃣ Persist the Ollama service URL in localvars for later use
OLLAMA_URL="http://ollama.ollama.svc.cluster.local:11434"
if grep -q '^OLLAMA_URL=' "$LOCALVARS"; then
  sed -i "s|^OLLAMA_URL=.*|OLLAMA_URL=\"$OLLAMA_URL\"|" "$LOCALVARS"
else
  echo "OLLAMA_URL=\"$OLLAMA_URL\"" >>"$LOCALVARS"
fi

# 6️⃣ Print out the HTTPS connection string for access (via a NodePort or Ingress)
#    Adjust as needed if you front it with TLS or an Ingress controller.
echo
echo "✅ Ollama deployed with persistence!"
echo "→ Internal cluster endpoint: $OLLAMA_URL"
echo
echo "If you’ve exposed it externally (e.g. via NodePort or Ingress), you can reach your LLM at:"
echo "     https://${MASTER}:11434/api/generate"
