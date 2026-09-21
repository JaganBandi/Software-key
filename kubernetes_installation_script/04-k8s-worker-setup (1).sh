#!/bin/bash

# ============================================================
#     KUBERNETES WORKER NODE - COMPLETE SETUP
# ============================================================
#
# OS        : Rocky Linux 9
# Kubernetes: 1.31
# Runtime   : containerd
# CNI       : Calico
#
# Controller:
#   Hostname : k8s-controller
#   IP       : 192.168.254.147
#
# Worker:
#   IP       : detected automatically
#   Hostname : entered during setup
#
# ============================================================

set -e

# ============================================================
# CONFIGURATION
# ============================================================

K8S_VERSION="1.31"

CONTROLLER_IP="192.168.254.147"
CONTROLLER_HOST="k8s-controller"

SSH_KEY="/root/.ssh/id_ed25519"
JOIN_FILE="/opt/k8s-worker-join.sh"

# ============================================================
# COLORS
# ============================================================

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"

# ============================================================
# FUNCTIONS
# ============================================================

ok()
{
    echo -e "${GREEN}[OK]${NC} $1"
}

info()
{
    echo -e "${YELLOW}[INFO]${NC} $1"
}

warn()
{
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error()
{
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    error "Run this script as root."
fi

clear

echo "============================================================"
echo "          KUBERNETES WORKER NODE SETUP"
echo "============================================================"
echo

echo "Controller:"
echo "  Hostname : ${CONTROLLER_HOST}"
echo "  IP       : ${CONTROLLER_IP}"
echo

# ============================================================
# WORKER INFORMATION
# ============================================================

echo "============================================================"
echo "              WORKER NODE INFORMATION"
echo "============================================================"

DETECTED_IP=$(hostname -I | awk '{print $1}')

echo
echo "Detected Worker IP: ${DETECTED_IP}"

read -rp "Enter this worker's cluster IP [${DETECTED_IP}]: " INPUT_IP
WORKER_IP="${INPUT_IP:-$DETECTED_IP}"

read -rp "Enter worker hostname [k8s-node1]: " INPUT_HOST
WORKER_HOST="${INPUT_HOST:-k8s-node1}"

echo
echo "Worker IP       : ${WORKER_IP}"
echo "Worker Hostname : ${WORKER_HOST}"
echo

# ============================================================
# HOSTNAME
# ============================================================

echo "============================================================"
echo "                 CONFIGURING HOSTNAME"
echo "============================================================"

hostnamectl set-hostname "$WORKER_HOST"

ok "Hostname configured: $(hostname)"

# ============================================================
# /etc/hosts
# ============================================================

echo
echo "============================================================"
echo "                 CONFIGURING /etc/hosts"
echo "============================================================"

cp /etc/hosts "/etc/hosts.backup.$(date +%Y%m%d%H%M%S)"

sed -i "\|[[:space:]]${CONTROLLER_HOST}$|d" /etc/hosts
sed -i "\|[[:space:]]${WORKER_HOST}$|d" /etc/hosts

cat >> /etc/hosts <<EOF

${CONTROLLER_IP}    ${CONTROLLER_HOST}
${WORKER_IP}        ${WORKER_HOST}
EOF

ok "/etc/hosts configured"

# ============================================================
# SWAP
# ============================================================

echo
echo "============================================================"
echo "                    DISABLE SWAP"
echo "============================================================"

swapoff -a

sed -i '/^[^#].*[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

ok "Swap disabled"

# ============================================================
# KERNEL MODULES
# ============================================================

echo
echo "============================================================"
echo "                  KERNEL MODULES"
echo "============================================================"

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

ok "overlay loaded"
ok "br_netfilter loaded"

# ============================================================
# SYSCTL
# ============================================================

echo
echo "============================================================"
echo "                 KERNEL PARAMETERS"
echo "============================================================"

cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null

IP_FORWARD=$(sysctl -n net.ipv4.ip_forward)

if [ "$IP_FORWARD" = "1" ]; then
    ok "net.ipv4.ip_forward = 1"
else
    error "IP forwarding is not enabled"
fi

# ============================================================
# FIREWALL
# ============================================================

echo
echo "============================================================"
echo "                    FIREWALL"
echo "============================================================"

if systemctl is-active --quiet firewalld; then

    firewall-cmd --permanent --add-port=10250/tcp >/dev/null
    firewall-cmd --permanent --add-port=30000-32767/tcp >/dev/null
    firewall-cmd --reload >/dev/null

    ok "Worker firewall configured"

else

    info "firewalld is not active"

fi

# ============================================================
# REQUIRED PACKAGES
# ============================================================

echo
echo "============================================================"
echo "                 REQUIRED PACKAGES"
echo "============================================================"

dnf install -y \
    conntrack-tools \
    socat \
    tar \
    wget \
    curl \
    ca-certificates \
    dnf-plugins-core \
    nmap-ncat \
    openssh-clients

ok "Required packages installed"

# ============================================================
# KUBERNETES REPOSITORY
# ============================================================

echo
echo "============================================================"
echo "              KUBERNETES REPOSITORY"
echo "============================================================"

cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

dnf clean all >/dev/null
dnf makecache >/dev/null

ok "Kubernetes repository configured"

# ============================================================
# KUBERNETES PACKAGES
# ============================================================

echo
echo "============================================================"
echo "             INSTALLING KUBERNETES PACKAGES"
echo "============================================================"

dnf install -y \
    kubelet \
    kubeadm \
    kubectl \
    --disableexcludes=kubernetes

ok "kubelet installed"
ok "kubeadm installed"
ok "kubectl installed"

echo
kubeadm version
echo

# ============================================================
# DOCKER REPOSITORY
# ============================================================

echo
echo "============================================================"
echo "              CONTAINERD REPOSITORY"
echo "============================================================"

if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then

    dnf config-manager \
        --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo

fi

ok "Docker repository configured"

# ============================================================
# CONTAINERD
# ============================================================

echo
echo "============================================================"
echo "                INSTALLING CONTAINERD"
echo "============================================================"

if command -v containerd >/dev/null 2>&1; then

    ok "containerd already installed"

else

    dnf install -y containerd.io

    ok "containerd installed"

fi

# ============================================================
# CONTAINERD CONFIGURATION
# ============================================================

echo
echo "============================================================"
echo "                CONFIGURING CONTAINERD"
echo "============================================================"

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

sed -i \
    's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

if grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
    ok "SystemdCgroup = true"
else
    error "Failed to configure SystemdCgroup"
fi

# ============================================================
# START CONTAINERD
# ============================================================

echo
echo "============================================================"
echo "                STARTING CONTAINERD"
echo "============================================================"

systemctl daemon-reload
systemctl enable --now containerd

if systemctl is-active --quiet containerd; then
    ok "containerd is active"
else
    error "containerd failed to start"
fi

# ============================================================
# CRICTL
# ============================================================

echo
echo "============================================================"
echo "                 CONFIGURING CRICTL"
echo "============================================================"

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

ok "crictl configured"

# ============================================================
# CRI CHECK
# ============================================================

echo
echo "============================================================"
echo "                  VERIFYING CRI"
echo "============================================================"

if crictl info >/tmp/crictl-info.txt 2>&1; then
    ok "containerd CRI is working"
else
    cat /tmp/crictl-info.txt
    error "CRI verification failed"
fi

# ============================================================
# KUBELET
# ============================================================

echo
echo "============================================================"
echo "                  CONFIGURING KUBELET"
echo "============================================================"

systemctl enable kubelet

systemctl start kubelet || true

sleep 5

if systemctl is-active --quiet kubelet; then
    ok "kubelet is active"
else
    info "kubelet is waiting for kubeadm join"
fi

# ============================================================
# PREREQUISITE VERIFICATION
# ============================================================

echo
echo "============================================================"
echo "              PREREQUISITE VERIFICATION"
echo "============================================================"

command -v conntrack >/dev/null \
    && ok "conntrack available" \
    || error "conntrack is missing"

command -v kubeadm >/dev/null \
    && ok "kubeadm available" \
    || error "kubeadm is missing"

command -v kubectl >/dev/null \
    && ok "kubectl available" \
    || error "kubectl is missing"

command -v kubelet >/dev/null \
    && ok "kubelet available" \
    || error "kubelet is missing"

command -v containerd >/dev/null \
    && ok "containerd available" \
    || error "containerd is missing"

# ============================================================
# API SERVER CONNECTIVITY
# ============================================================

echo
echo "============================================================"
echo "              API SERVER CONNECTIVITY"
echo "============================================================"

if nc -z -w 5 "$CONTROLLER_IP" 6443; then

    ok "API server port 6443 reachable"

else

    error "Cannot reach ${CONTROLLER_IP}:6443"

fi

API_STATUS=$(curl -ks \
    --connect-timeout 5 \
    "https://${CONTROLLER_IP}:6443/healthz" || true)

if [ "$API_STATUS" = "ok" ]; then

    ok "Kubernetes API server is healthy"

else

    error "Kubernetes API server health check failed"

fi

# ============================================================
# SSH KEY CONFIGURATION
# ============================================================

echo
echo "============================================================"
echo "          AUTOMATIC SSH KEY CONFIGURATION"
echo "============================================================"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

# ------------------------------------------------------------
# Generate SSH key automatically
# ------------------------------------------------------------

if [ ! -f "$SSH_KEY" ]; then

    info "SSH key not found."
    info "Generating ED25519 SSH key..."

    ssh-keygen \
        -t ed25519 \
        -f "$SSH_KEY" \
        -N "" \
        -C "k8s-worker-${WORKER_HOST}"

    ok "SSH key generated"

else

    ok "SSH key already exists"

fi

chmod 600 "$SSH_KEY"
chmod 644 "${SSH_KEY}.pub"

# ============================================================
# TEST PASSWORDLESS SSH
# ============================================================

echo
echo "============================================================"
echo "              CONTROLLER SSH CONNECTION"
echo "============================================================"

info "Testing SSH connection to controller..."

SSH_TEST=$(ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    root@"$CONTROLLER_IP" \
    "echo SSH_OK" 2>/dev/null || true)

# ============================================================
# COPY KEY IF REQUIRED
# ============================================================

if [ "$SSH_TEST" = "SSH_OK" ]; then

    ok "Passwordless SSH already configured"

else

    echo
    echo "============================================================"
    echo "       CONTROLLER ROOT PASSWORD REQUIRED"
    echo "============================================================"
    echo
    echo "Controller:"
    echo "  ${CONTROLLER_IP}"
    echo
    echo "The controller root password is required ONE TIME"
    echo "to install the worker SSH public key."
    echo

    ssh-copy-id \
        -i "${SSH_KEY}.pub" \
        -o StrictHostKeyChecking=no \
        root@"$CONTROLLER_IP"

    if [ $? -ne 0 ]; then

        error "Failed to copy SSH key to controller"

    fi

    ok "SSH public key copied to controller"

    echo
    info "Testing passwordless SSH again..."

    SSH_TEST=$(ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        root@"$CONTROLLER_IP" \
        "echo SSH_OK" 2>/dev/null || true)

    if [ "$SSH_TEST" = "SSH_OK" ]; then

        ok "Passwordless SSH configured successfully"

    else

        error "Worker cannot SSH to controller"

    fi

fi

# ============================================================
# VERIFY CONTROLLER HOSTNAME
# ============================================================

echo
echo "============================================================"
echo "             CONTROLLER SSH VERIFICATION"
echo "============================================================"

REMOTE_HOSTNAME=$(ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    root@"$CONTROLLER_IP" \
    "hostname")

if [ -n "$REMOTE_HOSTNAME" ]; then

    ok "Connected to controller: ${REMOTE_HOSTNAME}"

else

    error "Could not verify controller SSH"

fi

# ============================================================
# CHECK EXISTING WORKER CONFIGURATION
# ============================================================

if [ -f /etc/kubernetes/kubelet.conf ]; then

    echo
    echo "============================================================"
    echo "        EXISTING KUBERNETES CONFIGURATION DETECTED"
    echo "============================================================"

    warn "This worker appears to have joined a cluster previously."

    echo
    read -rp "Reset previous Kubernetes configuration? [y/N]: " RESET_NODE

    if [[ "$RESET_NODE" =~ ^[Yy]$ ]]; then

        info "Resetting previous Kubernetes configuration..."

        kubeadm reset -f

        rm -rf /etc/cni/net.d
        rm -rf /var/lib/cni
        rm -rf /etc/kubernetes/pki

        rm -f /etc/kubernetes/kubelet.conf
        rm -f /etc/kubernetes/bootstrap-kubelet.conf

        systemctl restart containerd
        systemctl restart kubelet

        ok "Previous Kubernetes configuration removed"

    else

        error "Existing Kubernetes configuration detected. Setup stopped."

    fi

fi

# ============================================================
# GENERATE FRESH JOIN COMMAND
# ============================================================

echo
echo "============================================================"
echo "            GENERATING FRESH JOIN COMMAND"
echo "============================================================"

JOIN_COMMAND=$(ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    root@"$CONTROLLER_IP" \
    "export KUBECONFIG=/etc/kubernetes/admin.conf; kubeadm token create --print-join-command")

if [[ "$JOIN_COMMAND" != kubeadm\ join* ]]; then

    echo
    echo "$JOIN_COMMAND"
    echo

    error "Failed to generate fresh Kubernetes join command"

fi

echo "$JOIN_COMMAND" > "$JOIN_FILE"

chmod 700 "$JOIN_FILE"

ok "Fresh join command generated"

echo
echo "Join command:"
echo
cat "$JOIN_FILE"
echo

# ============================================================
# KUBERNETES JOIN
# ============================================================

echo
echo "============================================================"
echo "               JOINING KUBERNETES CLUSTER"
echo "============================================================"

info "Executing kubeadm join..."

bash "$JOIN_FILE"

# ============================================================
# WAIT FOR KUBELET
# ============================================================

echo
echo "============================================================"
echo "                VERIFYING KUBELET"
echo "============================================================"

info "Waiting for kubelet..."

for i in {1..12}; do

    if systemctl is-active --quiet kubelet; then
        break
    fi

    sleep 5

done

if systemctl is-active --quiet kubelet; then

    ok "kubelet is active"

else

    systemctl status kubelet --no-pager || true

    error "kubelet is not active"

fi

# ============================================================
# VERIFY LOCAL KUBERNETES CONFIGURATION
# ============================================================

echo
echo "============================================================"
echo "             WORKER CONFIGURATION CHECK"
echo "============================================================"

if [ -f /etc/kubernetes/kubelet.conf ]; then

    ok "/etc/kubernetes/kubelet.conf exists"

else

    error "kubelet.conf was not created"

fi

# ============================================================
# FINAL INFORMATION
# ============================================================

echo
echo "============================================================"
echo "              WORKER SETUP COMPLETED"
echo "============================================================"

echo
echo "Worker:"
echo "  Hostname : $(hostname)"
echo "  IP       : ${WORKER_IP}"
echo "  Version  : $(kubeadm version -o short)"
echo

echo "Services:"
echo

echo -n "  containerd : "
systemctl is-active containerd

echo -n "  kubelet    : "
systemctl is-active kubelet

echo
echo "============================================================"
echo "                    SUCCESS"
echo "============================================================"

echo
echo "Worker ${WORKER_HOST} has successfully joined"
echo "the Kubernetes cluster."
echo

echo "Run on the controller:"
echo
echo "  export KUBECONFIG=/etc/kubernetes/admin.conf"
echo "  kubectl get nodes -o wide"
echo

echo "Expected:"
echo
echo "  k8s-controller    Ready    control-plane"
echo "  ${WORKER_HOST}    Ready    <none>"
echo

echo "============================================================"


