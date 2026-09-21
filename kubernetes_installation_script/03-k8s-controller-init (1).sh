#!/bin/bash

# ============================================================
# 03-k8s-controller-init.sh
#
# Kubernetes Control Plane Initialization
#
# Run AFTER:
#   01-k8s-cluster-config.sh
#   02-k8s-controller-setup.sh
#
# Supported:
#   AlmaLinux / Rocky Linux
#   Kubernetes 1.31.x
#   containerd
#   Calico
#
# ============================================================

set -e

# ============================================================
# Configuration
# ============================================================

CONFIG="/opt/k8s-cluster.conf"
JOIN_SCRIPT="/opt/k8s-worker-join.sh"

POD_NETWORK_CIDR="192.168.0.0/16"

CALICO_VERSION="v3.29.2"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# ============================================================
# Colors
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# Functions
# ============================================================

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

fail() {
    error "$1"
    exit 1
}

# ============================================================
# Root check
# ============================================================

if [ "$EUID" -ne 0 ]; then
    fail "This script must be executed as root."
fi

# ============================================================
# Configuration file check
# ============================================================

if [ ! -f "$CONFIG" ]; then

    error "Configuration file not found:"
    echo
    echo "  $CONFIG"
    echo

    echo "Run first:"
    echo
    echo "  /opt/01-k8s-cluster-config.sh"

    exit 1
fi

# ============================================================
# Load cluster configuration
# ============================================================

# shellcheck disable=SC1090
source "$CONFIG"

CONTROLLER_IP="$CONTROL_PLANE_1_IP"
CONTROLLER_HOST="$CONTROL_PLANE_1_HOST"

if [ -z "$CONTROLLER_IP" ]; then
    fail "CONTROL_PLANE_1_IP is missing from $CONFIG"
fi

if [ -z "$CONTROLLER_HOST" ]; then
    fail "CONTROL_PLANE_1_HOST is missing from $CONFIG"
fi

# ============================================================
# Header
# ============================================================

clear

echo
echo "============================================================"
echo "        KUBERNETES CONTROL-PLANE INITIALIZATION"
echo "============================================================"
echo

echo "Controller:"
echo "  Hostname : $CONTROLLER_HOST"
echo "  IP       : $CONTROLLER_IP"

echo
echo "Pod Network:"
echo "  CIDR     : $POD_NETWORK_CIDR"

echo
echo "Calico:"
echo "  Version  : $CALICO_VERSION"

echo
echo "============================================================"
echo

# ============================================================
# Verify hostname
# ============================================================

CURRENT_HOSTNAME=$(hostname)

if [ "$CURRENT_HOSTNAME" != "$CONTROLLER_HOST" ]; then

    warn "Current hostname: $CURRENT_HOSTNAME"
    warn "Expected hostname: $CONTROLLER_HOST"

    hostnamectl set-hostname "$CONTROLLER_HOST"

    ok "Hostname changed to: $CONTROLLER_HOST"

else

    ok "Hostname verified: $CONTROLLER_HOST"

fi

# ============================================================
# Verify controller IP
# ============================================================

if hostname -I | tr ' ' '\n' | grep -qx "$CONTROLLER_IP"; then

    ok "Controller IP verified: $CONTROLLER_IP"

else

    error "Controller IP $CONTROLLER_IP is not assigned to this server."

    echo
    echo "Detected IP addresses:"
    hostname -I

    exit 1

fi

# ============================================================
# Prerequisite verification
# ============================================================

echo
echo "============================================================"
echo "             PREREQUISITE VERIFICATION"
echo "============================================================"
echo

REQUIRED_COMMANDS=(
    kubeadm
    kubectl
    kubelet
    crictl
    conntrack
    containerd
)

for CMD in "${REQUIRED_COMMANDS[@]}"; do

    if command -v "$CMD" >/dev/null 2>&1; then

        ok "$CMD available"

    else

        error "$CMD is missing"
        echo
        echo "Please run the controller preparation script first:"
        echo
        echo "  /opt/02-k8s-controller-setup.sh"

        exit 1

    fi

done

# ============================================================
# Verify containerd
# ============================================================

echo

if systemctl is-active --quiet containerd; then

    ok "containerd is running"

else

    error "containerd is not running."

    echo
    echo "Check with:"
    echo
    echo "  systemctl status containerd"

    exit 1

fi

# ============================================================
# Verify CRI
# ============================================================

log "Checking containerd CRI..."

if crictl info >/tmp/k8s-crictl-info.txt 2>&1; then

    ok "containerd CRI is responding"

else

    error "containerd CRI is not responding."

    echo
    cat /tmp/k8s-crictl-info.txt

    exit 1

fi

# ============================================================
# Check kubelet
# ============================================================

if systemctl is-enabled kubelet >/dev/null 2>&1; then

    ok "kubelet is enabled"

else

    warn "kubelet is not enabled."

    systemctl enable kubelet

    ok "kubelet enabled"

fi

# ============================================================
# Check if cluster already initialized
# ============================================================

echo
echo "============================================================"
echo "             CLUSTER INITIALIZATION CHECK"
echo "============================================================"
echo

if [ -f /etc/kubernetes/admin.conf ]; then

    warn "Existing Kubernetes control-plane detected."

    export KUBECONFIG=/etc/kubernetes/admin.conf

    if kubectl cluster-info >/dev/null 2>&1; then

        ok "Existing Kubernetes API server is responding."

        echo
        echo "The cluster is already initialized."
        echo
        echo "kubeadm init will NOT be executed again."

    else

        error "/etc/kubernetes/admin.conf exists,"
        error "but Kubernetes API server is not responding."

        echo
        echo "Do NOT run kubeadm init automatically."
        echo
        echo "Investigate the existing cluster first."

        exit 1

    fi

else

    # ========================================================
    # kubeadm init
    # ========================================================

    echo
    echo "============================================================"
    echo "                  KUBEADM INITIALIZATION"
    echo "============================================================"
    echo

    log "Initializing Kubernetes control-plane..."

    kubeadm init \
        --apiserver-advertise-address="$CONTROLLER_IP" \
        --pod-network-cidr="$POD_NETWORK_CIDR"

    ok "kubeadm initialization completed."

fi

# ============================================================
# KUBECONFIG CONFIGURATION
# ============================================================

echo
echo "============================================================"
echo "                  KUBECTL CONFIGURATION"
echo "============================================================"
echo

if [ ! -f /etc/kubernetes/admin.conf ]; then

    fail "/etc/kubernetes/admin.conf was not created."

fi

# ------------------------------------------------------------
# Current script/session
# ------------------------------------------------------------

export KUBECONFIG=/etc/kubernetes/admin.conf

ok "KUBECONFIG exported for current session:"
echo
echo "  $KUBECONFIG"

# ------------------------------------------------------------
# Standard root kubeconfig
# ------------------------------------------------------------

mkdir -p /root/.kube

cp -f \
    /etc/kubernetes/admin.conf \
    /root/.kube/config

chmod 600 /root/.kube/config

ok "Root kubeconfig created:"
echo
echo "  /root/.kube/config"

# ------------------------------------------------------------
# Persistent KUBECONFIG
# ------------------------------------------------------------

cat > /root/.kube-env <<'EOF'
# Kubernetes administrator configuration
export KUBECONFIG=/etc/kubernetes/admin.conf
EOF

chmod 600 /root/.kube-env

ok "Persistent KUBECONFIG file created:"
echo
echo "  /root/.kube-env"

# ------------------------------------------------------------
# Add to root .bashrc
# ------------------------------------------------------------

if ! grep -qF 'source /root/.kube-env' /root/.bashrc 2>/dev/null; then

    echo 'source /root/.kube-env' >> /root/.bashrc

    ok "KUBECONFIG added to /root/.bashrc"

else

    ok "KUBECONFIG already exists in /root/.bashrc"

fi

# ============================================================
# Verify kubectl
# ============================================================

echo
echo "============================================================"
echo "                  KUBECTL VERIFICATION"
echo "============================================================"
echo

if kubectl cluster-info >/dev/null 2>&1; then

    ok "kubectl can connect to Kubernetes API"

else

    fail "kubectl cannot connect to Kubernetes API."

fi

echo
kubectl version --short 2>/dev/null || kubectl version

# ============================================================
# Current node status
# ============================================================

echo
echo "Current Kubernetes nodes:"
echo

kubectl get nodes -o wide

# ============================================================
# Install Calico
# ============================================================

echo
echo "============================================================"
echo "                    CALICO NETWORK"
echo "============================================================"
echo

if kubectl get daemonset calico-node \
    -n kube-system >/dev/null 2>&1; then

    warn "Calico is already installed."

else

    log "Installing Calico $CALICO_VERSION..."

    kubectl apply -f "$CALICO_URL"

    ok "Calico manifest applied successfully."

fi

# ============================================================
# Wait for Calico
# ============================================================

echo
log "Waiting for Calico to become ready..."

CALICO_READY=0

for i in $(seq 1 60); do

    DESIRED=$(kubectl get daemonset calico-node \
        -n kube-system \
        -o jsonpath='{.status.desiredNumberScheduled}' \
        2>/dev/null || echo "0")

    READY=$(kubectl get daemonset calico-node \
        -n kube-system \
        -o jsonpath='{.status.numberReady}' \
        2>/dev/null || echo "0")

    echo "  Calico: $READY/$DESIRED ready"

    if [ "$DESIRED" != "0" ] && [ "$READY" = "$DESIRED" ]; then

        CALICO_READY=1
        break

    fi

    sleep 5

done

if [ "$CALICO_READY" -eq 1 ]; then

    ok "Calico is ready."

else

    warn "Calico did not become fully ready within the expected time."

    echo
    kubectl get pods -n kube-system -o wide

fi

# ============================================================
# Wait for controller Ready
# ============================================================

echo
echo "============================================================"
echo "                CONTROLLER READINESS"
echo "============================================================"
echo

log "Waiting for $CONTROLLER_HOST to become Ready..."

NODE_READY=0

for i in $(seq 1 60); do

    STATUS=$(kubectl get node "$CONTROLLER_HOST" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || echo "Unknown")

    echo "  Controller status: $STATUS"

    if [ "$STATUS" = "True" ]; then

        NODE_READY=1
        break

    fi

    sleep 5

done

if [ "$NODE_READY" -eq 1 ]; then

    ok "Controller is Ready."

else

    error "Controller did not become Ready."

    echo
    echo "Nodes:"
    kubectl get nodes -o wide

    echo
    echo "System pods:"
    kubectl get pods -n kube-system -o wide

    exit 1

fi

# ============================================================
# Generate worker join command
# ============================================================

echo
echo "============================================================"
echo "              WORKER JOIN CONFIGURATION"
echo "============================================================"
echo

log "Generating worker join command..."

JOIN_COMMAND=$(kubeadm token create --print-join-command)

if [ -z "$JOIN_COMMAND" ]; then

    fail "Unable to generate worker join command."

fi

ok "Worker join command generated."

# ============================================================
# Create worker join script
# ============================================================

cat > "$JOIN_SCRIPT" <<EOF
#!/bin/bash

# ============================================================
# Kubernetes Worker Join Script
#
# Generated by:
# /opt/03-k8s-controller-init.sh
#
# Controller:
# $CONTROLLER_HOST
# $CONTROLLER_IP
#
# Run this script on a worker node as root.
# ============================================================

set -e

echo
echo "============================================================"
echo "              KUBERNETES WORKER JOIN"
echo "============================================================"
echo

if [ "\$EUID" -ne 0 ]; then
    echo "[ERROR] This script must be run as root."
    exit 1
fi

echo "[INFO] Joining worker to Kubernetes cluster..."
echo

$JOIN_COMMAND

echo
echo "============================================================"
echo "              WORKER JOIN COMPLETED"
echo "============================================================"
echo

echo "Return to the controller and run:"
echo
echo "  export KUBECONFIG=/etc/kubernetes/admin.conf"
echo "  kubectl get nodes -o wide"
echo

EOF

chmod 700 "$JOIN_SCRIPT"

ok "Worker join script created:"
echo
echo "  $JOIN_SCRIPT"

# ============================================================
# Final verification
# ============================================================

echo
echo "============================================================"
echo "             FINAL CLUSTER VERIFICATION"
echo "============================================================"
echo

echo "Kubernetes Nodes:"
echo

kubectl get nodes -o wide

echo
echo "Kubernetes System Pods:"
echo

kubectl get pods -n kube-system

echo
echo "Calico Pods:"
echo

kubectl get pods \
    -n kube-system \
    -l k8s-app=calico-node \
    -o wide

# ============================================================
# Final summary
# ============================================================

echo
echo "============================================================"
echo "       KUBERNETES CONTROLLER INITIALIZATION COMPLETE"
echo "============================================================"
echo

echo "Controller:"
echo "  Hostname : $CONTROLLER_HOST"
echo "  IP       : $CONTROLLER_IP"

echo
echo "Kubernetes:"
kubeadm version -o short 2>/dev/null || true

echo
echo "Pod Network:"
echo "  CIDR     : $POD_NETWORK_CIDR"

echo
echo "Calico:"
echo "  Version  : $CALICO_VERSION"

echo
echo "KUBECONFIG:"
echo "  $KUBECONFIG"

echo
echo "Root kubeconfig:"
echo "  /root/.kube/config"

echo
echo "Worker join script:"
echo "  $JOIN_SCRIPT"

echo
echo "============================================================"
echo "NEXT STEP"
echo "============================================================"
echo
echo "Prepare k8s-node1 and k8s-node2."
echo
echo "Do NOT run kubeadm init on worker nodes."
echo
echo "Worker join script:"
echo
echo "  $JOIN_SCRIPT"
echo
echo "============================================================"

