#!/usr/bin/env bash
set -euo pipefail

### 1) Load & validate localvars ###
LOCALVARS="./localvars"
if [[ ! -r "$LOCALVARS" ]]; then
  echo "ERROR: cannot read $LOCALVARS" >&2
  exit 1
fi
source "$LOCALVARS"

# Expand & check SSH key
SSH_KEY_PATH="${MY_SSH_KEY/#\~/$HOME}"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "ERROR: MY_SSH_KEY not found at $SSH_KEY_PATH" >&2
  exit 1
fi

# Required vars
: "${DEVICE:?DEVICE must be set in localvars}"
: "${MOUNTPOINT:?MOUNTPOINT must be set in localvars}"
: "${POD_CIDR:?POD_CIDR must be set in localvars}"
: "${USER:?USER must be set in localvars}"
if (( ${#NODES[@]} == 0 )); then
  echo "ERROR: NODES array must be defined in localvars" >&2
  exit 1
fi

MASTER="${NODES[0]}"

# SSH options, pointing at your key
SSH_OPTS=(-i "$SSH_KEY_PATH" \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null)

# State tracking
unreachable=()
bootstrap_failed=()
join_failed=()
init_failed=false

### 2) Bootstrap a node ###
bootstrap_node() {
  local host=$1
  ssh "${SSH_OPTS[@]}" "${USER}@${host}" sudo bash <<'EOF'
set -e

echo "[BOOTSTRAP] Updating apt cache"
apt-get update -qq

echo "[BOOTSTRAP] Installing prerequisites"
apt-get install -qq -y apt-transport-https ca-certificates curl gnupg lsb-release

echo "[BOOTSTRAP] Adding Kubernetes apt repo"
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<KR >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
KR

echo "[BOOTSTRAP] Updating apt cache (after adding repos)"
apt-get update -qq

echo "[BOOTSTRAP] Installing containerd, kubelet, kubeadm, kubectl"
apt-get install -qq -y containerd kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "[BOOTSTRAP] Disabling swap"
swapoff -a
sed -i '/ swap /s/^/#/' /etc/fstab

echo "[BOOTSTRAP] Setting sysctl params for networking"
modprobe br_netfilter
cat <<SYSCTL >/etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

echo "[BOOTSTRAP] Preparing data dirs and bind‑mounts"
for D in containerd kubelet; do
  mkdir -p /data/$D /var/lib/$D
  chown root:root /data/$D
  mount --bind /data/$D /var/lib/$D 2>/dev/null || true
  grep -q "/data/$D /var/lib/$D" /etc/fstab || \
    echo "/data/$D /var/lib/$D none bind 0 0" >> /etc/fstab
done

echo "[BOOTSTRAP] Configuring containerd"
containerd config default | \
  sed -e 's#root =.*#root = "/data/containerd"#' \
      -e 's#state =.*#state = "/data/containerd/run"#' \
  > /etc/containerd/config.toml
systemctl restart containerd

echo "[BOOTSTRAP] Pointing kubelet at /data"
echo 'KUBELET_EXTRA_ARGS="--root-dir=/data/kubelet"' > /etc/default/kubelet
systemctl daemon-reload

echo "[BOOTSTRAP] Complete"
EOF
}

### 3) Initialize master ###
init_master() {
  ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" sudo bash <<EOF
set -e

if [ -f /etc/kubernetes/admin.conf ]; then
  echo "[MASTER INIT] already initialized"
  exit 0
fi

echo "[MASTER INIT] Generating kubeadm config"
cat <<KADM > /etc/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER}
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    root-dir: /data/kubelet
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "${POD_CIDR}"
etcd:
  local:
    dataDir: /data/etcd
KADM

echo "[MASTER INIT] Running kubeadm init"
kubeadm init --config /etc/kubeadm-config.yaml

echo "[MASTER INIT] Configuring kubectl for ${USER}"
mkdir -p /home/${USER}/.kube
cp -i /etc/kubernetes/admin.conf /home/${USER}/.kube/config
chown ${USER}:${USER} /home/${USER}/.kube/config

echo "[MASTER INIT] Deploying network (Flannel)"
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "[MASTER INIT] Installing Argo CD"
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "[MASTER INIT] Complete"
EOF
}

### 4) Join a worker ###
join_worker() {
  local host=$1
  echo "[JOIN] Fetching join command"
  local cmd
  cmd=$(ssh "${SSH_OPTS[@]}" "${USER}@${MASTER}" sudo kubeadm token create --print-join-command)

  echo "[JOIN] Running join on ${host}"
  ssh "${SSH_OPTS[@]}" "${USER}@${host}" sudo bash <<EOF
set -e
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "[JOIN] already joined"
  exit 0
fi
${cmd}
echo "[JOIN] Complete"
EOF
}

### 5) Bootstrap all nodes ###
for host in "${NODES[@]}"; do
  printf "> %s: " "$host"
  if ! ssh "${SSH_OPTS[@]}" "${USER}@${host}" true &>/dev/null; then
    echo "unreachable"
    unreachable+=("$host")
    continue
  fi

  if bootstrap_node "$host"; then
    echo "bootstrapped"
  else
    echo "bootstrap FAILED"
    bootstrap_failed+=("$host")
  fi
done

### 6) Init master ###
if [[ " ${unreachable[*]} " == *" ${MASTER} "* ]] || [[ " ${bootstrap_failed[*]} " == *" ${MASTER} "* ]]; then
  echo "→ skipping master init (unready)"
  init_failed=true
else
  printf "> initializing master: "
  if init_master; then
    echo "OK"
  else
    echo "FAILED"
    init_failed=true
  fi
fi

### 7) Join workers ###
for host in "${NODES[@]:1}"; do
  if [[ " ${unreachable[*]} " == *" ${host} "* ]] || [[ " ${bootstrap_failed[*]} " == *" ${host} "* ]]; then
    continue
  fi

  printf "> joining %s: " "$host"
  if join_worker "$host"; then
    echo "OK"
  else
    echo "FAILED"
    join_failed+=("$host")
  fi
done

### 8) Summary ###
echo
(( ${#unreachable[@]}    )) && printf "Unreachable:      %s\n" "${unreachable[*]}"
(( ${#bootstrap_failed[@]} )) && printf "Bootstrap failed: %s\n" "${bootstrap_failed[*]}"
[[ "$init_failed" == true ]] && echo "Master init:      FAILED"
(( ${#join_failed[@]}   )) && printf "Join failed:      %s\n" "${join_failed[*]}"

echo
echo "To access the Argo CD UI:"
echo "  ssh -i \"$SSH_KEY_PATH\" -L 8080:localhost:443 ${USER}@${MASTER} &"
echo "  open http://localhost:8080"
