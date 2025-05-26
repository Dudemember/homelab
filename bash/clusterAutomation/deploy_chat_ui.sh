#!/usr/bin/env bash
set -euo pipefail

# ── Load localvars ───────────────────────────────────────────────────────────
LOCALVARS="$(dirname "$0")/localvars"
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read \$LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

# ── Sanity checks ─────────────────────────────────────────────────────────────
: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
(( ${#NODES[@]} > 0 )) || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }
: "${OLLAMA_NAMESPACE:?OLLAMA_NAMESPACE must be set in localvars}"
: "${CHAT_UI_NODE_PORT:?CHAT_UI_NODE_PORT must be set in localvars}"

# ── SSH config & pick master ─────────────────────────────────────────────────
SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
MASTER="${NODES[0]}"

echo "→ Deploying Chat UI to $MASTER (NodePort: $CHAT_UI_NODE_PORT)"

# ── SSH in and deploy ─────────────────────────────────────────────────────────
ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" \
    MASTER="$MASTER" \
    OLLAMA_NAMESPACE="$OLLAMA_NAMESPACE" \
    CHAT_UI_NODE_PORT="$CHAT_UI_NODE_PORT" \
  bash <<'EOF'
set -euo pipefail

# shorthand for k3s kubectl
K="sudo k3s kubectl"

echo "→ remote: ensuring namespace $OLLAMA_NAMESPACE"
$K create namespace "$OLLAMA_NAMESPACE" --dry-run=client -o yaml | $K apply -f -

echo "→ remote: deploying Chatbot UI frontend"
# Deployment
$K apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-ui
  namespace: $OLLAMA_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chat-ui
  template:
    metadata:
      labels:
        app: chat-ui
    spec:
      containers:
      - name: chatbot-ui
        image: ghcr.io/mckaywrigley/chatbot-ui:main
        env:
        - name: OPENAI_API_KEY
          value: "sk-FAKE-KEY"
        - name: OPENAI_API_HOST
          value: "http://ollama.$OLLAMA_NAMESPACE.svc.cluster.local:11434"
        ports:
        - containerPort: 3000
YAML

echo "→ remote: exposing Chat UI via NodePort $CHAT_UI_NODE_PORT"
# Service → NodePort
$K apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: chat-ui
  namespace: $OLLAMA_NAMESPACE
spec:
  type: NodePort
  selector:
    app: chat-ui
  ports:
    - port: 80
      targetPort: 3000
      nodePort: $CHAT_UI_NODE_PORT
      protocol: TCP
YAML

echo "→ remote: waiting for Chat UI rollout"
$K rollout status deployment/chat-ui -n "$OLLAMA_NAMESPACE"

# Broadcast the external URL
echo "✅ remote: Chat UI is live at http://$MASTER:$CHAT_UI_NODE_PORT"
EOF

echo "🏁 deploy_chat_ui.sh complete."
