#!/bin/bash

# ============================================================
# Kubernetes Controller Preparation Script
# Rocky Linux 9 / AlmaLinux 9
# Kubernetes 1.31.x
# containerd + CRI + systemd cgroups
# ============================================================

set -e

CONFIG="/opt/k8s-cluster.conf"
K8S_VERSION="1.31"
CONTAINERD_VERSION="2.3.3"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    error "Run this script as root."
    exit 1
fi

echo
echo "============================================================"
echo "        KUBERNETES CONTROLLER PREPARATION"
echo "============================================================"
echo

# ------------------------------------------------------------
# Load cluster configuration
# ------------------------------------------------------------

if [ ! -f "$CONFIG" ]; then
    error "$CONFIG not found."
    echo
    echo "Run the cluster configuration script first:"
    echo
    echo "    /opt/01-k8s-cluster-config.sh"
    echo
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

if [ -z "$CONTROL_PLANE_1_IP" ]; then
    error "CONTROL_PLANE_1_IP is missing from $CONFIG"
    exit 1
fi

if [ -z "$CONTROL_PLANE_1_HOST" ]; then
    error "CONTROL_PLANE_1_HOST is missing from $CONFIG"
    exit 1
fi

CONTROLLER_IP="$CONTROL_PLANE_1_IP"
CONTROLLER_HOST="$CONTROL_PLANE_1_HOST"

# ------------------------------------------------------------
# Detect server IP
# ------------------------------------------------------------

SERVER_IPS=$(hostname -I)

if ! echo "$SERVER_IPS" | tr ' ' '\n' | grep -qx "$CONTROLLER_IP"; then
    error "This server does not have controller IP: $CONTROLLER_IP"
    echo
    echo "Detected IPs:"
    echo "$SERVER_IPS"
    exit 1
fi

ok "Controller IP verified: $CONTROLLER_IP"

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

CURRENT_HOSTNAME=$(hostname)

if [ "$CURRENT_HOSTNAME" != "$CONTROLLER_HOST" ]; then
    log "Setting hostname to $CONTROLLER_HOST"
    hostnamectl set-hostname "$CONTROLLER_HOST"
    ok "Hostname changed to $CONTROLLER_HOST"
else
    ok "Hostname already correct: $CONTROLLER_HOST"
fi

# ------------------------------------------------------------
# /etc/hosts
# ------------------------------------------------------------

log "Updating /etc/hosts"

cp -a /etc/hosts "/etc/hosts.backup.$(date +%Y%m%d-%H%M%S)"

# Remove previous Kubernetes entries created by this setup
sed -i '/# KUBERNETES-CLUSTER-START/,/# KUBERNETES-CLUSTER-END/d' /etc/hosts

cat >> /etc/hosts <<EOF

# KUBERNETES-CLUSTER-START
${CONTROL_PLANE_1_IP}    ${CONTROL_PLANE_1_HOST}
EOF

for i in $(seq 1 "${WORKER_COUNT:-0}"); do

    eval IP=\$WORKER_${i}_IP
    eval HOST=\$WORKER_${i}_HOST

    if [ -n "$IP" ] && [ -n "$HOST" ]; then
        echo "${IP}    ${HOST}" >> /etc/hosts
    fi

done

cat >> /etc/hosts <<EOF
# KUBERNETES-CLUSTER-END
EOF

ok "/etc/hosts updated"

# ------------------------------------------------------------
# Disable swap
# ------------------------------------------------------------

log "Disabling swap"

swapoff -a

sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

ok "Swap disabled"

# ------------------------------------------------------------
# SELinux
# ------------------------------------------------------------

if command -v getenforce >/dev/null 2>&1; then

    SELINUX_STATUS=$(getenforce)

    if [ "$SELINUX_STATUS" != "Disabled" ]; then
        warn "SELinux is $SELINUX_STATUS"

        setenforce 0 || true

        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        sed -i 's/^SELINUX=disabled/SELINUX=permissive/' /etc/selinux/config

        ok "SELinux configured as permissive"
    else
        ok "SELinux already disabled"
    fi

fi

# ------------------------------------------------------------
# Kernel modules
# ------------------------------------------------------------

log "Configuring Kubernetes kernel modules"

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

ok "Kernel modules loaded"

# ------------------------------------------------------------
# Kubernetes sysctl
# ------------------------------------------------------------

log "Configuring Kubernetes networking parameters"

cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null

ok "Kernel networking parameters configured"

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

if systemctl is-active --quiet firewalld; then

    log "Configuring firewalld"

    firewall-cmd --permanent --add-port=6443/tcp
    firewall-cmd --permanent --add-port=2379-2380/tcp
    firewall-cmd --permanent --add-port=10250/tcp
    firewall-cmd --permanent --add-port=10257/tcp
    firewall-cmd --permanent --add-port=10259/tcp

    firewall-cmd --reload >/dev/null

    ok "Controller firewall ports configured"

else
    warn "firewalld is not active"
fi

# ------------------------------------------------------------
# Repository
# ------------------------------------------------------------

log "Configuring Kubernetes repository"

cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

ok "Kubernetes repository configured"

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

log "Installing Kubernetes packages"

dnf install -y \
    conntrack \
    kubelet \
    kubeadm \
    kubectl \
    cri-tools \
    --disableexcludes=kubernetes

ok "Kubernetes packages installed"

# ------------------------------------------------------------
# containerd repository
# ------------------------------------------------------------

log "Configuring Docker repository for containerd"

dnf install -y dnf-plugins-core >/dev/null

if ! dnf repolist | grep -q docker-ce-stable; then
    dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
fi

# ------------------------------------------------------------
# containerd
# ------------------------------------------------------------

if command -v containerd >/dev/null 2>&1; then
    INSTALLED_CONTAINERD=$(containerd --version | awk '{print $3}')
    ok "containerd already installed: $INSTALLED_CONTAINERD"
else

    log "Installing containerd"

    dnf install -y containerd.io

    ok "containerd installed"

fi

# ------------------------------------------------------------
# containerd configuration
# ------------------------------------------------------------

log "Generating clean containerd configuration"

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

# ------------------------------------------------------------
# SystemdCgroup
# ------------------------------------------------------------

if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
        /etc/containerd/config.toml
fi

# ------------------------------------------------------------
# Verify CRI section
# ------------------------------------------------------------

if ! grep -q "io.containerd.grpc.v1.cri" /etc/containerd/config.toml; then
    error "CRI configuration was not found in containerd configuration."
    exit 1
fi

# IMPORTANT:
# Do NOT add disabled_plugins=["cri"]

if grep -q '^disabled_plugins.*cri' /etc/containerd/config.toml; then
    sed -i '/^disabled_plugins.*cri/d' /etc/containerd/config.toml
fi

ok "containerd CRI enabled"

# ------------------------------------------------------------
# Start containerd
# ------------------------------------------------------------

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

if ! systemctl is-active --quiet containerd; then
    error "containerd failed to start"
    systemctl status containerd --no-pager
    exit 1
fi

ok "containerd is active"

# ------------------------------------------------------------
# crictl configuration
# ------------------------------------------------------------

log "Configuring crictl"

crictl config \
    runtime-endpoint \
    unix:///run/containerd/containerd.sock

crictl config \
    image-endpoint \
    unix:///run/containerd/containerd.sock

ok "crictl configured"

# ------------------------------------------------------------
# Verify CRI
# ------------------------------------------------------------

log "Checking containerd CRI"

if ! crictl info >/dev/null 2>&1; then

    error "CRI runtime check failed."

    echo
    echo "containerd status:"
    systemctl status containerd --no-pager

    echo
    echo "containerd CRI logs:"
    journalctl -u containerd --no-pager -n 30

    exit 1
fi

ok "CRI runtime is working"

# ------------------------------------------------------------
# Verify SystemdCgroup
# ------------------------------------------------------------

if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    ok "SystemdCgroup = true"
else
    error "SystemdCgroup is not enabled"
    exit 1
fi

# ------------------------------------------------------------
# Kubelet
# ------------------------------------------------------------

systemctl enable kubelet

ok "Kubelet enabled"

# ------------------------------------------------------------
# Version verification
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                 VERSION INFORMATION"
echo "============================================================"

echo
echo "containerd:"
containerd --version

echo
echo "kubeadm:"
kubeadm version -o short

echo
echo "kubelet:"
kubelet --version

echo
echo "kubectl:"
kubectl version --client --short 2>/dev/null || kubectl version --client

echo
echo "CRI:"
crictl info 2>/dev/null | grep -E '"containerdEndpoint"|"RuntimeReady"' || true

echo
echo "IP forwarding:"
sysctl net.ipv4.ip_forward

echo
echo "============================================================"
echo "       CONTROLLER PREPARATION COMPLETED SUCCESSFULLY"
echo "============================================================"
echo

echo "Controller:"
echo "  Hostname : $(hostname)"
echo "  IP       : $CONTROLLER_IP"

echo
echo "Workers:"

for i in $(seq 1 "${WORKER_COUNT:-0}"); do
    eval IP=\$WORKER_${i}_IP
    eval HOST=\$WORKER_${i}_HOST

    if [ -n "$IP" ] && [ -n "$HOST" ]; then
        echo "  $HOST : $IP"
    fi
done

echo
echo "IMPORTANT:"
echo
echo "This script ONLY prepares the controller."
echo
echo "It does NOT run:"
echo
echo "  kubeadm init"
echo "  kubectl apply"
echo "  kubeadm join"
echo
echo "The next script will initialize the Kubernetes"
echo "control-plane."
echo
echo "============================================================"


