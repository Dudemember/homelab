#!/usr/bin/env bash
set -uo pipefail
# NOTE: we omit -e so failures don’t abort the whole run

# ——— 0) Load your localvars ———
LOCALVARS="./localvars"
if [[ ! -f "$LOCALVARS" ]]; then
  echo "ERROR: '$LOCALVARS' not found" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$LOCALVARS"

# ——— 1) Validate required vars ———
if [[ -z "${NODES+x}" ]] || (( ${#NODES[@]} == 0 )); then
  echo "ERROR: NODES array is not defined or empty in '$LOCALVARS'" >&2
  exit 1
fi
: "${USER:?   USER must be set in $LOCALVARS}"
: "${POD_CIDR:? POD_CIDR must be set in $LOCALVARS}"

# ——— 2) Configuration from localvars ———
MASTER="${NODES[0]}"

# ——— 3) State tracking ———
unreachable=()
bootstrap_failed=()
join_failed=()
init_failed=false

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no)

# ——— 4) Functions ———
bootstrap_node() {
  local host=$1
  ssh "${SSH_OPTS[@]}" "$USER@$host" sudo bash <<'EOF'
set -e

# install & prep
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release \
                   containerd.io kubelet kubeadm kubectl
swapoff -a
sed -i '/ swap /s/^/#/' /etc/fstab

# kernel networking
modprobe br_netfilter
cat <<SYSCTL >/etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

# prepare data dirs
for D in containerd kubelet; do
  mkdir -p /data/$D
  chown root:root /data/$D
  # bind‑mount it over the default path
  mkdir -p /var/lib/$D
  mount --bind /data/$D /var/lib/$D || true
  grep -q "/data/$D /var/lib/$D" /etc/fstab \
    || echo "/data/$D /var/lib/$D none bind 0 0" >> /etc/fstab
done

# reconfigure containerd
containerd config default | \
  sed -e 's#root =.*#root = "/data/containerd"#' \
      -e 's#state =.*#state = "/data/containerd/run"#' \
  > /etc/containerd/config.toml
systemctl restart containerd

# point kubelet at /data
echo 'KUBELET_EXTRA_ARGS="--root-dir=/data/kubelet"' > /etc/default/kubelet
systemctl daemon-reload

EOF
}

init_master() {
  ssh "${SSH_OPTS[@]}" "$USER@$MASTER" sudo bash <<EOF
set -e
if [ ! -f /etc/kubernetes/admin.conf ]; then
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

  kubeadm init --config /etc/kubeadm-config.yaml

  mkdir -p /home/${USER}/.kube
  cp -i /etc/kubernetes/admin.conf /home/${USER}/.kube/config
  chown ${USER}:${USER} /home/${USER}/.kube/config

  # install networking & Argo CD
  kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  kubectl create namespace argocd || true
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
fi
EOF
}

join_worker() {
  local host=$1
  ssh "${SSH_OPTS[@]}" "$USER@$MASTER" sudo kubeadm token create --print-join-command 2>/dev/null | \
    ssh "${SSH_OPTS[@]}" "$USER@$host" sudo bash -c '
      if [ ! -f /etc/kubernetes/kubelet.conf ]; then
        bash
      fi
    '
}

# ——— 5) Bootstrap all nodes ———
for h in "${NODES[@]}"; do
  printf "> %s: " "$h"
  if ! ssh "${SSH_OPTS[@]}" "$USER@$h" true &>/dev/null; then
    echo "unreachable"
    unreachable+=("$h")
    continue
  fi

  if bootstrap_node "$h"; then
    echo "bootstrapped"
  else
    echo "bootstrap FAILED"
    bootstrap_failed+=("$h")
  fi
done

# ——— 6) Init master ———
if [[ " ${unreachable[*]} " =~ " ${MASTER} " ]] || [[ " ${bootstrap_failed[*]} " =~ " ${MASTER} " ]]; then
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

# ——— 7) Join workers ———
for h in "${NODES[@]:1}"; do
  if [[ " ${unreachable[*]} " =~ " ${h} " ]] || [[ " ${bootstrap_failed[*]} " =~ " ${h} " ]]; then
    continue
  fi

  printf "> joining %s: " "$h"
  if join_worker "$h"; then
    echo "OK"
  else
    echo "FAILED"
    join_failed+=("$h")
  fi
done

# ——— 8) Summary ———
echo
(( ${#unreachable[@]}    )) && printf "Unreachable:      %s\n" "${unreachable[*]}"
(( ${#bootstrap_failed[@]} )) && printf "Bootstrap failed: %s\n" "${bootstrap_failed[*]}"
init_failed            && echo    "Master init:      FAILED"
(( ${#join_failed[@]}   )) && printf "Join failed:      %s\n" "${join_failed[*]}"

echo
echo "To access Argo CD UI (if init succeeded):"
echo "  ssh -L 8080:localhost:443 ${USER}@${MASTER} &"
echo "  open http://localhost:8080"
