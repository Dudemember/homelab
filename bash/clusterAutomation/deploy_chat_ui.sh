#!/usr/bin/env bash
set -euo pipefail

# ─── Load localvars ──────────────────────────────────────────────────────────
LOCALVARS="$(dirname "$0")/localvars"
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
(( ${#NODES[@]} > 0 ))   || { echo "ERROR: NODES must be defined in localvars" >&2; exit 1; }
: "${OLLAMA_NAMESPACE:?OLLAMA_NAMESPACE must be set in localvars}"
: "${OLLAMA_URL:?OLLAMA_URL must be set in localvars}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL must be set in localvars}"
: "${CHAT_UI_NODE_PORT:?CHAT_UI_NODE_PORT must be set in localvars}"

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=( 
  -i "$SSH_KEY" 
  -o BatchMode=yes 
  -o ConnectTimeout=5 
  -o StrictHostKeyChecking=no 
  -o UserKnownHostsFile=/dev/null 
)
MASTER="${NODES[0]}"

echo "→ Deploying Gradio Chat UI to $MASTER:$CHAT_UI_NODE_PORT"

ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" bash <<EOF
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 1) Namespace
sudo k3s kubectl create namespace $OLLAMA_NAMESPACE --dry-run=client -o yaml \
  | sudo k3s kubectl apply -f -

# 2) ConfigMap for the Gradio app script
sudo k3s kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: gradio-chat-ui-script
  namespace: $OLLAMA_NAMESPACE
data:
  app.py: |
    import os, requests, gradio as gr

    OLLAMA_URL = os.environ["OLLAMA_URL"]
    MODEL = os.environ["OLLAMA_MODEL"]

    def chat(prompt):
        resp = requests.post(
            f"{OLLAMA_URL}/v1/chat/completions",
            json={"model": MODEL, "messages": [{"role":"user","content":prompt}]}
        )
        return resp.json()["choices"][0]["message"]["content"]

    gr.Interface(fn=chat, inputs="text", outputs="text", title="Ollama Chat").launch(
        server_name="0.0.0.0", server_port=7860, share=False
    )
YAML

# 3) Deployment + Service
sudo k3s kubectl apply -f - <<YAML
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gradio-chat-ui
  namespace: $OLLAMA_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels: { app: gradio-chat-ui }
  template:
    metadata:
      labels: { app: gradio-chat-ui }
    spec:
      containers:
      - name: gradio-chat-ui
        image: python:3.11-slim
        command: ["/bin/bash","-c"]
        args:
        - |
          pip install gradio requests && \
          python /scripts/app.py
        env:
        - name: OLLAMA_URL
          value: "$OLLAMA_URL"
        - name: OLLAMA_MODEL
          value: "$OLLAMA_MODEL"
        ports:
        - containerPort: 7860
        volumeMounts:
        - name: script
          mountPath: /scripts
      volumes:
      - name: script
        configMap:
          name: gradio-chat-ui-script
---
apiVersion: v1
kind: Service
metadata:
  name: gradio-chat-ui
  namespace: $OLLAMA_NAMESPACE
spec:
  type: NodePort
  selector:
    app: gradio-chat-ui
  ports:
  - port: 80
    targetPort: 7860
    nodePort: $CHAT_UI_NODE_PORT
    protocol: TCP
YAML

# 4) Wait + broadcast
sudo k3s kubectl rollout status deployment/gradio-chat-ui -n $OLLAMA_NAMESPACE
echo "✅ remote: Gradio Chat UI is live at http://$MASTER:$CHAT_UI_NODE_PORT"
EOF

echo "🏁 deploy_chat_ui.sh complete."
