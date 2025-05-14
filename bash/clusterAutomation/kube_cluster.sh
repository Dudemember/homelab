#!/usr/bin/env bash
set -e

nodes=(192.168.1.101 192.168.1.102 192.168.1.103 192.168.1.104 192.168.1.105)
user=ubuntu

# 1) bootstrap each Ubuntu node
for h in "${nodes[@]}"; do
  ssh-copy-id "$user@$h"
  ssh "$user@$h" sudo bash <<'EOF'
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
echo "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y containerd.io kubelet kubeadm kubectl
swapoff -a
sed -i '/ swap /s/^/#/' /etc/fstab
modprobe br_netfilter
echo -e "net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1" \
  > /etc/sysctl.d/99-k8s.conf
sysctl --system
EOF
done

master=${nodes[0]}

# 2) init control‑plane + CNI + Argo CD (once)
ssh "$user@$master" bash <<'EOF'
if [ ! -f /etc/kubernetes/admin.conf ]; then
  kubeadm init --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address=$master
  mkdir -p \$HOME/.kube
  cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
  chown \$(id -u):\$(id -g) \$HOME/.kube/config
  kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  kubectl create namespace argocd || true
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
fi
EOF

# 3) join any workers not yet joined
join=$(ssh "$user@$master" kubeadm token create --print-join-command)
for h in "${nodes[@]:1}"; do
  ssh "$user@$h" bash -c "if [ ! -f /etc/kubernetes/kubelet.conf ]; then sudo $join; fi"
done

# 4) show you how to reach the Argo CD UI
printf "\nssh -L 8080:localhost:443 %s@%s &\nopen http://localhost:8080\n" \
  "$user" "$master"
