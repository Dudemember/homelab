#!/usr/bin/env bash
set -euo pipefail

# ─── Load your localvars ──────────────────────────────────────────────────────
LOCALVARS="$(dirname "$0")/localvars"
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

# ─── SSH config ───────────────────────────────────────────────────────────────
SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

# ─── Master node & SSH target ─────────────────────────────────────────────────
MASTER_NODE="${NODES[0]}"
SSH_TARGET="${USER}@${MASTER_NODE}"

# ─── kubectl wrapper ───────────────────────────────────────────────────────────
KUBECTL="sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"

# ─── Execute all on master via SSH ────────────────────────────────────────────
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" bash <<EOF
set -euo pipefail

# 1) Ensure namespace exists
${KUBECTL} create namespace ${DIFY_NAMESPACE} --dry-run=client -o yaml \
  | ${KUBECTL} apply -f -

# 2) Create PVCs if missing
if ! ${KUBECTL} get pvc my-chatbot-dify -n ${DIFY_NAMESPACE} &>/dev/null; then
  cat <<YAML | ${KUBECTL} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-chatbot-dify
  namespace: ${DIFY_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
YAML
else
  echo "↳ PVC my-chatbot-dify exists; skipping"
fi

if ! ${KUBECTL} get pvc my-chatbot-dify-plugin-daemon -n ${DIFY_NAMESPACE} &>/dev/null; then
  cat <<YAML | ${KUBECTL} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-chatbot-dify-plugin-daemon
  namespace: ${DIFY_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
YAML
else
  echo "↳ PVC my-chatbot-dify-plugin-daemon exists; skipping"
fi

# 3) Deploy/Update Dify
cat <<YAML | ${KUBECTL} apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-chatbot-dify
  namespace: ${DIFY_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-chatbot-dify
  template:
    metadata:
      labels:
        app: my-chatbot-dify
    spec:
      containers:
      - name: dify
        image: difyai/dify:latest
        ports:
        - containerPort: 8080
        env:
        - name: PUBLIC_DIFY_URL
          value: "http://${MASTER_NODE}:${DIFY_NODE_PORT}"
        - name: OPENAI_API_BASE
          value: "http://ollama.${DIFY_NAMESPACE}.svc.cluster.local:11434"
        - name: OPENAI_API_KEY
          value: "PLACEHOLDER_API_KEY"
        volumeMounts:
        - name: data
          mountPath: /app/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: my-chatbot-dify
YAML

# 4) Create Service if missing
if ! ${KUBECTL} get svc my-chatbot-dify -n ${DIFY_NAMESPACE} &>/dev/null; then
  cat <<YAML | ${KUBECTL} apply -f -
apiVersion: v1
kind: Service
metadata:
  name: my-chatbot-dify
  namespace: ${DIFY_NAMESPACE}
spec:
  type: NodePort
  selector:
    app: my-chatbot-dify
  ports:
  - port: 8080
    targetPort: 8080
    nodePort: ${DIFY_NODE_PORT}
    protocol: TCP
YAML
else
  echo "↳ Service my-chatbot-dify exists; skipping"
fi

# 5) Wait for rollout
echo "⏳ Waiting for Dify to roll out..."
${KUBECTL} rollout status deployment/my-chatbot-dify -n ${DIFY_NAMESPACE}

echo "✅ Dify available at http://${MASTER_NODE}:${DIFY_NODE_PORT}"
EOF

echo "🏁 deploy_dify.sh complete."
