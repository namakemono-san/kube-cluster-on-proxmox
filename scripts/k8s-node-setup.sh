#!/usr/bin/env bash
set -eu


# region : script usage

function usage() {
    echo "usage> k8s-node-setup.sh [COMMAND] [TARGET_BRANCH]"
    echo "[COMMAND]:"
    echo "  alcaris-k8s-cp-1    Run setup script for control-plane node (only cp node)"
    echo "  alcaris-k8s-wk-*    Run setup script for worker node(s)"
}
if [[ $# -lt 1 ]]; then
    usage
    exit 255
fi

case $1 in
    alcaris-k8s-cp-1|alcaris-k8s-wk-*)
        ;;
    help)
        usage
        exit 255
        ;;
    *)
        usage
        exit 255
        ;;
esac
# endregion


# region : variables

TARGET_BRANCH=${2:-master}
CP_IP=$(hostname -I | awk '{print $1}')
KUBE_VERSION="1.27.1-00"
REPOSITORY_SOURCE_URL="https://github.com/namakemono-san/kube-cluster-on-proxmox.git"
REPOSITORY_RAW_SOURCE_URL="https://raw.githubusercontent.com/namakemono-san/kube-cluster-on-proxmox/master"
# endregion


# region : setup for all nodes (common configuration)

# Load necessary kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Set sysctl parameters required for Kubernetes
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

# Install prerequisites and containerd
apt-get update && apt-get install -y apt-transport-https curl gnupg2
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y containerd.io

# Configure containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
if ! grep -q "SystemdCgroup = true" "/etc/containerd/config.toml"; then
    sed -i -e "s/SystemdCgroup \= false/SystemdCgroup \= true/g" /etc/containerd/config.toml
fi
sudo systemctl restart containerd

# Additional kernel parameters for Kubernetes
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10
kernel.panic_on_oops = 1
EOF
sudo sysctl --system

# Install kubelet, kubeadm, and kubectl
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet=${KUBE_VERSION} kubeadm=${KUBE_VERSION} kubectl=${KUBE_VERSION}
apt-mark hold kubelet kubeadm kubectl

# Disable swap
swapoff -a

# Create crictl configuration file
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF
# endregion


# region : worker node processing (if command is worker, exit here)

case $1 in
    alcaris-k8s-wk-*)
        exit 0
        ;;
esac
# endregion


# region : setup for control-plane node (alcaris-k8s-cp-1)

# Generate a kubeadm bootstrap token
KUBEADM_BOOTSTRAP_TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)

# Create kubeadm init configuration file
cat <<EOF > "$HOME"/init_kubeadm.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- token: "$KUBEADM_BOOTSTRAP_TOKEN"
  description: "kubeadm bootstrap token"
  ttl: "24h"
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  serviceSubnet: "10.96.0.0/16"
  podSubnet: "10.128.0.0/16"
kubernetesVersion: "v1.27.1"
# Use this node's IP as the control plane endpoint for a single CP setup
controlPlaneEndpoint: "${CP_IP}:6443"
apiServer:
  certSANs:
  - "${CP_IP}"
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
protectKernelDefaults: true
EOF

# Initialize the Kubernetes cluster (skipping the kube-proxy phase)
kubeadm init --config "$HOME"/init_kubeadm.yaml --skip-phases=addon/kube-proxy --ignore-preflight-errors=NumCPU,Mem

# Set up kubectl configuration for the current user
mkdir -p "$HOME"/.kube
cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# Install Helm CLI
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Install Cilium (CNI plugin) via Helm
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --namespace kube-system --set kubeProxyReplacement=strict --set k8sServiceHost=${CP_IP} --set k8sServicePort=6443

# Install ArgoCD via Helm using values from your repository
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
    --version 5.36.10 \
    --create-namespace \
    --namespace argocd \
    --values "${REPOSITORY_RAW_SOURCE_URL}/k8s-manifests/argocd-helm-chart-values.yaml"
helm install argocd-apps argo/argocd-apps \
    --version 0.0.1 \
    --values "${REPOSITORY_RAW_SOURCE_URL}/k8s-manifests/argocd-apps-helm-chart-values.yaml"
# endregion


# region : post-control-plane: generate join config for worker nodes

cat <<EOF > "$HOME"/join_kubeadm_wk.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
protectKernelDefaults: true
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CP_IP}:6443"
    token: "$KUBEADM_BOOTSTRAP_TOKEN"
    unsafeSkipCAVerification: true
EOF

echo "Worker join configuration saved at: $HOME/join_kubeadm_wk.yaml"
# endregion


# region : optionally trigger additional setup via Ansible

apt-get install -y ansible git sshpass
git clone -b "${TARGET_BRANCH}" "${REPOSITORY_SOURCE_URL}" "$HOME"/kube-cluster-on-proxmox
export ANSIBLE_CONFIG="$HOME"/kube-cluster-on-proxmox/ansible/ansible.cfg
ansible-galaxy role install -r "$HOME"/kube-cluster-on-proxmox/ansible/roles/requirements.yaml
ansible-galaxy collection install -r "$HOME"/kube-cluster-on-proxmox/ansible/roles/requirements.yaml
ansible-playbook -i "$HOME"/kube-cluster-on-proxmox/ansible/hosts/k8s-servers/inventory "$HOME"/kube-cluster-on-proxmox/ansible/site.yaml
# endregion
