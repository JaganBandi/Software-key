#!/usr/bin/env bash
# master-monitoring-installer.sh
# AlmaLinux / Rocky Linux 9.x
# One script for Prometheus, Grafana and Node Exporter.
# No server IPs are hard-coded. The script asks for them at runtime.
# It also configures Asia/Kolkata time and chrony on Linux monitoring servers.

set -Eeuo pipefail
IFS=$'\n\t'

PROMETHEUS_VERSION="3.6.0"
NODE_EXPORTER_VERSION="1.9.1"
TIMEZONE="Asia/Kolkata"
PROMETHEUS_PORT="9090"
GRAFANA_PORT="3000"
NODE_EXPORTER_PORT="9100"

LOG_FILE="/var/log/master-monitoring-installer.log"
PROM_USER="prometheus"
NODE_USER="node_exporter"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo; echo "ERROR: installation stopped at line $LINENO."; echo "Check $LOG_FILE for details."; exit 1' ERR

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run this script as root."
        exit 1
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
    else
        echo "Cannot detect Linux distribution."
        exit 1
    fi

    case "${ID:-}" in
        almalinux|rocky|rhel|centos|ol)
            ;;
        *)
            echo "This script is intended for AlmaLinux/Rocky/RHEL-compatible 9.x systems."
            echo "Detected: ${PRETTY_NAME:-unknown}"
            exit 1
            ;;
    esac
}

install_base_packages() {
    echo "Installing required base packages..."
    dnf install -y curl wget tar gzip firewalld chrony ca-certificates \
        policycoreutils policycoreutils-python-utils selinux-policy-targeted \
        shadow-utils openssl
}

configure_time() {
    echo
    echo "============================================================"
    echo "TIME SYNCHRONIZATION"
    echo "============================================================"

    timedatectl set-timezone "$TIMEZONE"

    systemctl enable --now chronyd

    # Use a stable public NTP pool plus Cloudflare/Google fallbacks.
    # chrony keeps the distribution defaults unless these are absent.
    cat > /etc/chrony.conf <<'EOF'
pool pool.ntp.org iburst
server time.cloudflare.com iburst
server time.google.com iburst
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
EOF

    systemctl restart chronyd
    sleep 3

    chronyc -a makestep || true
    sleep 2

    timedatectl set-ntp true || true

    echo
    timedatectl
    echo
    chronyc tracking || true
}

get_local_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}
    }')

    if [[ -z "${ip:-}" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    echo "$ip"
}

ask_local_ip() {
    local detected answer
    detected="$(get_local_ip)"

    echo
    echo "Detected local IPv4 address: ${detected:-not detected}"
    read -r -p "Use this IP? [y/n]: " answer

    if [[ "${answer,,}" == "y" && -n "${detected:-}" ]]; then
        LOCAL_IP="$detected"
    else
        read -r -p "Enter this server's IPv4 address: " LOCAL_IP
    fi

    if ! [[ "$LOCAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Invalid IPv4 address: $LOCAL_IP"
        exit 1
    fi
}

open_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    systemctl enable --now firewalld

    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
    firewall-cmd --reload >/dev/null
}

create_user_if_missing() {
    local user="$1"
    if ! id "$user" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /sbin/nologin "$user"
    fi
}

download_release() {
    local url="$1"
    local output="$2"
    local tmp="${output}.tmp"

    rm -f "$tmp"
    echo "Downloading: $url"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 "$url" -o "$tmp"
    test -s "$tmp"
    mv -f "$tmp" "$output"
}

setup_selinux_binary_context() {
    local path="$1"

    # /usr/local/bin is normally executable under SELinux, but explicitly
    # restore the standard executable context and create a persistent rule.
    if command_exists semanage; then
        semanage fcontext -a -t bin_t "$path" 2>/dev/null || \
        semanage fcontext -m -t bin_t "$path"
        restorecon -v "$path" || true
    fi
}

install_prometheus() {
    echo
    echo "============================================================"
    echo "PROMETHEUS SERVER"
    echo "============================================================"

    ask_local_ip

    local add_nodes node1_ip node2_ip
    PROM_TARGETS=""

    read -r -p "Add Node Exporter targets now? [y/n]: " add_nodes

    if [[ "${add_nodes,,}" == "y" ]]; then
        read -r -p "Enter Node-1 IP: " node1_ip
        if [[ ! "$node1_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "Invalid Node-1 IP."
            exit 1
        fi
        PROM_TARGETS="        - '${node1_ip}:${NODE_EXPORTER_PORT}'"

        read -r -p "Add Node-2 also? [y/n]: " add_nodes
        if [[ "${add_nodes,,}" == "y" ]]; then
            read -r -p "Enter Node-2 IP: " node2_ip
            if [[ ! "$node2_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo "Invalid Node-2 IP."
                exit 1
            fi
            PROM_TARGETS="${PROM_TARGETS}
        - '${node2_ip}:${NODE_EXPORTER_PORT}'"
        fi
    fi

    create_user_if_missing "$PROM_USER"

    mkdir -p /etc/prometheus /var/lib/prometheus
    chown -R "$PROM_USER:$PROM_USER" /etc/prometheus /var/lib/prometheus

    local archive="/tmp/prometheus-${PROMETHEUS_VERSION}.tar.gz"
    local url="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"

    download_release "$url" "$archive"

    rm -rf "/tmp/prometheus-${PROMETHEUS_VERSION}"
    tar -xzf "$archive" -C /tmp

    install -m 0755 "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /usr/local/bin/prometheus
    install -m 0755 "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" /usr/local/bin/promtool

    setup_selinux_binary_context /usr/local/bin/prometheus
    setup_selinux_binary_context /usr/local/bin/promtool

    chown root:root /usr/local/bin/prometheus /usr/local/bin/promtool

    cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets:
          - "${LOCAL_IP}:${PROMETHEUS_PORT}"
EOF

    if [[ -n "$PROM_TARGETS" ]]; then
        cat >> /etc/prometheus/prometheus.yml <<EOF

  - job_name: "node_exporter"
    static_configs:
      - targets:
${PROM_TARGETS}
EOF
    fi

    chown -R "$PROM_USER:$PROM_USER" /etc/prometheus /var/lib/prometheus

    # Validate configuration before starting.
    /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml

    cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus Monitoring Server
Wants=network-online.target
After=network-online.target chronyd.service

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable prometheus
    systemctl restart prometheus
    sleep 5

    if ! systemctl is-active --quiet prometheus; then
        systemctl status prometheus --no-pager || true
        journalctl -u prometheus -n 50 --no-pager || true
        echo "Prometheus did not start."
        exit 1
    fi

    open_firewall_port "$PROMETHEUS_PORT"

    echo
    echo "Prometheus service:"
    systemctl --no-pager --full status prometheus | sed -n '1,14p'

    echo
    echo "Prometheus URL: http://${LOCAL_IP}:${PROMETHEUS_PORT}"
    echo "Ready check:    http://${LOCAL_IP}:${PROMETHEUS_PORT}/-/ready"
}

install_node_exporter() {
    echo
    echo "============================================================"
    echo "NODE EXPORTER SERVER"
    echo "============================================================"

    ask_local_ip

    create_user_if_missing "$NODE_USER"

    local archive="/tmp/node_exporter-${NODE_EXPORTER_VERSION}.tar.gz"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

    download_release "$url" "$archive"

    rm -rf "/tmp/node_exporter-${NODE_EXPORTER_VERSION}"
    tar -xzf "$archive" -C /tmp

    install -m 0755 "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
    setup_selinux_binary_context /usr/local/bin/node_exporter
    chown root:root /usr/local/bin/node_exporter

    cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target chronyd.service

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl restart node_exporter
    sleep 3

    if ! systemctl is-active --quiet node_exporter; then
        systemctl status node_exporter --no-pager || true
        journalctl -u node_exporter -n 50 --no-pager || true
        exit 1
    fi

    open_firewall_port "$NODE_EXPORTER_PORT"

    if ! curl -fsS "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" >/dev/null; then
        echo "Node Exporter is running but the metrics endpoint is not responding."
        exit 1
    fi

    echo
    echo "Node Exporter URL: http://${LOCAL_IP}:${NODE_EXPORTER_PORT}/metrics"
    echo "Node Exporter service is UP."
}

install_grafana_repo() {
    cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

    dnf clean all >/dev/null 2>&1 || true
    dnf makecache
    dnf install -y grafana
}

install_grafana() {
    echo
    echo "============================================================"
    echo "GRAFANA SERVER"
    echo "============================================================"

    ask_local_ip

    local prometheus_ip
    read -r -p "Enter Prometheus Server IP: " prometheus_ip

    if ! [[ "$prometheus_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Invalid Prometheus IP."
        exit 1
    fi

    install_grafana_repo

    # Configure timezone.
    if grep -q '^default_timezone' /etc/grafana/grafana.ini; then
        sed -i 's/^default_timezone.*/default_timezone = Asia\\/Kolkata/' /etc/grafana/grafana.ini
    else
        sed -i '/^\[date\]/a default_timezone = Asia/Kolkata' /etc/grafana/grafana.ini
    fi

    mkdir -p /etc/grafana/provisioning/datasources

    cat > /etc/grafana/provisioning/datasources/prometheus.yml <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://${prometheus_ip}:${PROMETHEUS_PORT}
    isDefault: true
    editable: true
EOF

    systemctl daemon-reload
    systemctl enable --now grafana-server
    systemctl restart grafana-server
    sleep 7

    if ! systemctl is-active --quiet grafana-server; then
        systemctl status grafana-server --no-pager || true
        journalctl -u grafana-server -n 50 --no-pager || true
        exit 1
    fi

    open_firewall_port "$GRAFANA_PORT"

    if ! curl -fsS "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null; then
        echo "Grafana service is running but health endpoint failed."
        exit 1
    fi

    echo
    echo "Grafana URL: http://${LOCAL_IP}:${GRAFANA_PORT}"
    echo "Prometheus datasource configured: http://${prometheus_ip}:${PROMETHEUS_PORT}"
    echo "Default login on a fresh Grafana install is normally admin / admin."
    echo "Grafana may force a password change on first login."
}

verify_target_connectivity() {
    local target_ip="$1"
    echo "Checking Node Exporter at ${target_ip}:${NODE_EXPORTER_PORT}..."
    if curl -fsS --connect-timeout 5 "http://${target_ip}:${NODE_EXPORTER_PORT}/metrics" >/dev/null; then
        echo "  OK: ${target_ip}:${NODE_EXPORTER_PORT}"
        return 0
    else
        echo "  WARNING: cannot reach ${target_ip}:${NODE_EXPORTER_PORT}"
        return 1
    fi
}

print_summary() {
    echo
    echo "============================================================"
    echo "INSTALLATION SUMMARY"
    echo "============================================================"
    echo "Log file: $LOG_FILE"
    echo
    echo "Time zone: $TIMEZONE"
    echo "NTP: chronyd"
    echo
    echo "Prometheus:  http://<PROMETHEUS-IP>:${PROMETHEUS_PORT}"
    echo "Grafana:     http://<GRAFANA-IP>:${GRAFANA_PORT}"
    echo "Node Exporter: http://<NODE-IP>:${NODE_EXPORTER_PORT}/metrics"
    echo
    echo "IMPORTANT:"
    echo "Replace <...-IP> with the IP you entered during installation."
    echo "No server IP addresses are stored permanently in this script."
}

full_setup() {
    echo
    echo "============================================================"
    echo "FULL MONITORING SETUP"
    echo "============================================================"
    echo "This option installs the selected components one at a time."
    echo "It does NOT assume that all components are on the same server."
    echo

    while true; do
        echo
        echo "Choose the component to configure on THIS server:"
        echo "1. Prometheus Server"
        echo "2. Grafana Server"
        echo "3. Node Exporter"
        echo "4. Finish"
        read -r -p "Enter choice [1-4]: " choice

        case "$choice" in
            1) install_prometheus ;;
            2) install_grafana ;;
            3) install_node_exporter ;;
            4) break ;;
            *) echo "Invalid choice." ;;
        esac
    done

    print_summary
}

main_menu() {
    require_root
    detect_os
    install_base_packages
    configure_time

    echo
    echo "============================================================"
    echo " MASTER MONITORING INSTALLER"
    echo "============================================================"
    echo
    echo "Welcome!"
    echo "This single script can configure:"
    echo "  1. Prometheus Server"
    echo "  2. Grafana Server"
    echo "  3. Node Exporter"
    echo
    echo "No monitoring server IP is hard-coded."
    echo "The script asks for the required IP addresses when needed."
    echo

    read -r -p "Are you going to configure the monitoring setup? [y/n]: " answer
    if [[ "${answer,,}" != "y" ]]; then
        echo "Exiting."
        exit 0
    fi

    while true; do
        echo
        echo "============================================================"
        echo "SELECT SERVER ROLE FOR THIS SERVER"
        echo "============================================================"
        echo "1. Prometheus Server"
        echo "2. Grafana Server"
        echo "3. Node Exporter"
        echo "4. Full / Multiple Component Setup"
        echo "5. Exit"
        echo
        read -r -p "Enter choice [1-5]: " choice

        case "$choice" in
            1) install_prometheus; break ;;
            2) install_grafana; break ;;
            3) install_node_exporter; break ;;
            4) full_setup; break ;;
            5) echo "Exiting."; exit 0 ;;
            *) echo "Invalid choice. Please enter 1-5." ;;
        esac
    done

    echo
    echo "============================================================"
    echo "SUCCESS"
    echo "============================================================"
    echo "Configuration completed."
    print_summary
}

main_menu "$@"

