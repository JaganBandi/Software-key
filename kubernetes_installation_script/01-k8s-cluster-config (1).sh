#!/bin/bash

set -euo pipefail

CONFIG_FILE="/opt/k8s-cluster.conf"
HOSTS_FILE="/etc/hosts"

# ============================================================
# Kubernetes Cluster Configuration Wizard
# Interactive / Dynamic Version
# ============================================================

clear

echo
echo "============================================================"
echo "       Kubernetes Cluster Configuration Wizard"
echo "============================================================"
echo
echo "This script will:"
echo
echo "  1. Ask whether you are ready"
echo "  2. Allow you to wait for a maximum time"
echo "  3. Allow ENTER to continue immediately"
echo "  4. Ask number of Control Plane servers"
echo "  5. Ask number of Worker Nodes"
echo "  6. Collect IP addresses"
echo "  7. Collect hostnames"
echo "  8. Update /etc/hosts"
echo "  9. Detect the current server automatically"
echo " 10. Set hostname when required"
echo " 11. Create /opt/k8s-cluster.conf"
echo
echo "============================================================"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

# ------------------------------------------------------------
# Validate IPv4
# ------------------------------------------------------------

validate_ipv4()
{
    local IP="$1"

    if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS='.' read -r a b c d <<< "$IP"

    for octet in "$a" "$b" "$c" "$d"
    do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done

    return 0
}

# ------------------------------------------------------------
# Wait function
#
# User can:
#
#   ENTER -> continue immediately
#   timeout -> continue after requested minutes
#   Ctrl+C -> cancel
# ------------------------------------------------------------

wait_for_user()
{
    local MINUTES
    local TOTAL_SECONDS
    local REMAINING
    local M
    local S

    echo
    echo "============================================================"
    echo "                Preparation Check"
    echo "============================================================"
    echo
    echo "Before continuing, make sure you have:"
    echo
    echo "  [1] Control Plane IP address(es)"
    echo "  [2] Worker Node IP address(es)"
    echo "  [3] Hostnames"
    echo "  [4] Network connectivity"
    echo
    echo "Example:"
    echo
    echo "  Controller : 192.168.254.147"
    echo "  Node 1     : 192.168.254.155"
    echo "  Node 2     : 192.168.254.156"
    echo

    while true
    do

        echo
        read -rp \
        "Are you ready with the cluster IP addresses? [Y/N]: " \
        READY

        case "$READY" in

            Y|y)

                echo
                echo "[OK] You are ready."
                echo "[OK] Continuing..."
                return 0
                ;;

            N|n)

                echo
                echo "No problem."
                echo
                echo "You can collect the information now."
                echo

                while true
                do

                    read -rp \
                    "Do you want the script to wait for you? [Y/N]: " \
                    WAIT_CHOICE

                    case "$WAIT_CHOICE" in

                        Y|y)
                            break
                            ;;

                        N|n)

                            echo
                            echo "Script stopped safely."
                            echo
                            echo "Run it again when you are ready."
                            exit 0
                            ;;

                        *)

                            echo
                            echo "[ERROR] Please enter Y or N."

                            ;;

                    esac

                done

                while true
                do

                    echo
                    read -rp \
                    "Maximum waiting time in minutes [5]: " \
                    MINUTES

                    MINUTES=${MINUTES:-5}

                    if [[ "$MINUTES" =~ ^[1-9][0-9]*$ ]]; then
                        break
                    fi

                    echo
                    echo "[ERROR] Enter a valid number greater than zero."

                done

                TOTAL_SECONDS=$((MINUTES * 60))

                echo
                echo "============================================================"
                echo " Waiting for maximum $MINUTES minute(s)"
                echo "============================================================"
                echo
                echo "IMPORTANT:"
                echo
                echo "  Press ENTER at any time when you are ready."
                echo "  You do NOT have to wait for the full time."
                echo
                echo "  Press Ctrl+C to cancel."
                echo
                echo "============================================================"
                echo

                # ------------------------------------------------
                # Countdown
                #
                # read -t allows ENTER to interrupt the countdown.
                # ------------------------------------------------

                while (( TOTAL_SECONDS > 0 ))
                do

                    M=$((TOTAL_SECONDS / 60))
                    S=$((TOTAL_SECONDS % 60))

                    printf "\rTime remaining: %02d:%02d | Press ENTER when ready " \
                        "$M" "$S"

                    # Wait for ENTER for one second.
                    # If ENTER is received, continue immediately.

                    if read -r -t 1; then

                        echo
                        echo
                        echo "============================================================"
                        echo "          ENTER received - Continuing now"
                        echo "============================================================"
                        echo

                        return 0

                    fi

                    TOTAL_SECONDS=$((TOTAL_SECONDS - 1))

                done

                echo
                echo
                echo "============================================================"
                echo " Maximum waiting time completed"
                echo "============================================================"
                echo

                echo "Please confirm that you are ready."

                ;;

            *)

                echo
                echo "[ERROR] Please enter Y or N."

                ;;

        esac

    done
}

# ============================================================
# STEP 1 - Readiness
# ============================================================

wait_for_user

# ============================================================
# STEP 2 - Number of servers
# ============================================================

echo
echo "============================================================"
echo "             Cluster Server Count"
echo "============================================================"
echo

while true
do

    read -rp \
    "How many CONTROL PLANE servers? [1]: " \
    CONTROL_PLANE_COUNT

    CONTROL_PLANE_COUNT=${CONTROL_PLANE_COUNT:-1}

    if [[ "$CONTROL_PLANE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        break
    fi

    echo "[ERROR] Enter a valid positive number."

done

while true
do

    read -rp \
    "How many WORKER NODE servers? [2]: " \
    WORKER_COUNT

    WORKER_COUNT=${WORKER_COUNT:-2}

    if [[ "$WORKER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        break
    fi

    echo "[ERROR] Enter a valid positive number."

done

# ============================================================
# Arrays
# ============================================================

declare -a CONTROL_PLANE_IPS
declare -a CONTROL_PLANE_HOSTS

declare -a WORKER_IPS
declare -a WORKER_HOSTS

declare -a ALL_IPS
declare -a ALL_HOSTS

# ============================================================
# STEP 3 - Control Plane Information
# ============================================================

echo
echo "============================================================"
echo "              Control Plane Configuration"
echo "============================================================"

for ((i=1; i<=CONTROL_PLANE_COUNT; i++))
do

    echo
    echo "CONTROL PLANE $i"
    echo "------------------------------------------------------------"

    while true
    do

        read -rp "IP Address: " CP_IP

        if validate_ipv4 "$CP_IP"; then
            break
        fi

        echo "[ERROR] Invalid IPv4 address."

    done

    if (( i == 1 )); then
        DEFAULT_CP_HOST="k8s-controller"
    else
        DEFAULT_CP_HOST="k8s-controller-$i"
    fi

    read -rp \
    "Hostname [$DEFAULT_CP_HOST]: " \
    CP_HOST

    CP_HOST=${CP_HOST:-$DEFAULT_CP_HOST}

    CONTROL_PLANE_IPS[$i]="$CP_IP"
    CONTROL_PLANE_HOSTS[$i]="$CP_HOST"

    ALL_IPS+=("$CP_IP")
    ALL_HOSTS+=("$CP_HOST")

done

# ============================================================
# STEP 4 - Worker Information
# ============================================================

echo
echo "============================================================"
echo "                 Worker Configuration"
echo "============================================================"

for ((i=1; i<=WORKER_COUNT; i++))
do

    echo
    echo "WORKER NODE $i"
    echo "------------------------------------------------------------"

    while true
    do

        read -rp "IP Address: " WORKER_IP

        if validate_ipv4 "$WORKER_IP"; then
            break
        fi

        echo "[ERROR] Invalid IPv4 address."

    done

    DEFAULT_WORKER_HOST="k8s-node$i"

    read -rp \
    "Hostname [$DEFAULT_WORKER_HOST]: " \
    WORKER_HOST

    WORKER_HOST=${WORKER_HOST:-$DEFAULT_WORKER_HOST}

    WORKER_IPS[$i]="$WORKER_IP"
    WORKER_HOSTS[$i]="$WORKER_HOST"

    ALL_IPS+=("$WORKER_IP")
    ALL_HOSTS+=("$WORKER_HOST")

done

# ============================================================
# STEP 5 - Duplicate validation
# ============================================================

echo
echo "============================================================"
echo "                Validating Configuration"
echo "============================================================"

for ((i=0; i<${#ALL_IPS[@]}; i++))
do

    for ((j=i+1; j<${#ALL_IPS[@]}; j++))
    do

        if [[ "${ALL_IPS[$i]}" == "${ALL_IPS[$j]}" ]]; then

            echo
            echo "[ERROR] Duplicate IP address detected:"
            echo "${ALL_IPS[$i]}"
            echo
            echo "Please run the script again."
            exit 1

        fi

        if [[ "${ALL_HOSTS[$i]}" == "${ALL_HOSTS[$j]}" ]]; then

            echo
            echo "[ERROR] Duplicate hostname detected:"
            echo "${ALL_HOSTS[$i]}"
            echo
            echo "Please run the script again."
            exit 1

        fi

    done

done

echo "[OK] No duplicate IP addresses."
echo "[OK] No duplicate hostnames."

# ============================================================
# STEP 6 - Display Summary
# ============================================================

echo
echo "============================================================"
echo "                  Cluster Summary"
echo "============================================================"
echo

echo "CONTROL PLANES : $CONTROL_PLANE_COUNT"
echo

for ((i=1; i<=CONTROL_PLANE_COUNT; i++))
do

    printf "  %-18s %-25s CONTROL-PLANE\n" \
        "${CONTROL_PLANE_IPS[$i]}" \
        "${CONTROL_PLANE_HOSTS[$i]}"

done

echo
echo "WORKER NODES : $WORKER_COUNT"
echo

for ((i=1; i<=WORKER_COUNT; i++))
do

    printf "  %-18s %-25s WORKER\n" \
        "${WORKER_IPS[$i]}" \
        "${WORKER_HOSTS[$i]}"

done

echo
echo "============================================================"
echo

read -rp \
"Is this configuration correct? [Y/N]: " \
CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

    echo
    echo "[INFO] Configuration cancelled."
    echo
    echo "No changes were made."
    exit 0

fi

# ============================================================
# STEP 7 - Create configuration file
# ============================================================

echo
echo "[INFO] Creating:"
echo "$CONFIG_FILE"

cat > "$CONFIG_FILE" <<EOF
# ============================================================
# Kubernetes Cluster Configuration
# Generated: $(date)
# ============================================================

CONTROL_PLANE_COUNT="$CONTROL_PLANE_COUNT"
WORKER_COUNT="$WORKER_COUNT"
EOF

for ((i=1; i<=CONTROL_PLANE_COUNT; i++))
do

    cat >> "$CONFIG_FILE" <<EOF
CONTROL_PLANE_${i}_IP="${CONTROL_PLANE_IPS[$i]}"
CONTROL_PLANE_${i}_HOST="${CONTROL_PLANE_HOSTS[$i]}"
EOF

done

for ((i=1; i<=WORKER_COUNT; i++))
do

    cat >> "$CONFIG_FILE" <<EOF
WORKER_${i}_IP="${WORKER_IPS[$i]}"
WORKER_${i}_HOST="${WORKER_HOSTS[$i]}"
EOF

done

chmod 600 "$CONFIG_FILE"

echo "[OK] Configuration file created."

# ============================================================
# STEP 8 - Backup /etc/hosts
# ============================================================

HOSTS_BACKUP="/etc/hosts.backup.$(date +%Y%m%d-%H%M%S)"

cp "$HOSTS_FILE" "$HOSTS_BACKUP"

echo
echo "[OK] /etc/hosts backup:"
echo "$HOSTS_BACKUP"

# ============================================================
# STEP 9 - Remove old Kubernetes host entries
# ============================================================

sed -i \
    -e '/[[:space:]]k8s-controller[0-9-]*[[:space:]]*$/d' \
    -e '/[[:space:]]k8s-node[0-9-]*[[:space:]]*$/d' \
    "$HOSTS_FILE"

# ============================================================
# STEP 10 - Add Kubernetes hosts
# ============================================================

cat >> "$HOSTS_FILE" <<EOF

# ============================================================
# Kubernetes Cluster
# ============================================================
EOF

for ((i=1; i<=CONTROL_PLANE_COUNT; i++))
do

    echo "${CONTROL_PLANE_IPS[$i]}    ${CONTROL_PLANE_HOSTS[$i]}" \
        >> "$HOSTS_FILE"

done

for ((i=1; i<=WORKER_COUNT; i++))
do

    echo "${WORKER_IPS[$i]}    ${WORKER_HOSTS[$i]}" \
        >> "$HOSTS_FILE"

done

echo "# ============================================================" \
    >> "$HOSTS_FILE"

echo
echo "[OK] /etc/hosts updated."

# ============================================================
# STEP 11 - Detect current server IP
# ============================================================

CURRENT_IP=$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '
    {
        for(i=1;i<=NF;i++)
            if($i=="src")
            {
                print $(i+1)
                exit
            }
    }')

if [[ -z "$CURRENT_IP" ]]; then

    CURRENT_IP=$(hostname -I | awk '{print $1}')

fi

echo
echo "Current server detected IP:"
echo "$CURRENT_IP"

# ============================================================
# STEP 12 - Determine current server role
# ============================================================

CURRENT_ROLE="UNKNOWN"
CURRENT_HOST=""

for ((i=1; i<=CONTROL_PLANE_COUNT; i++))
do

    if [[ "$CURRENT_IP" == "${CONTROL_PLANE_IPS[$i]}" ]]; then

        CURRENT_ROLE="CONTROL-PLANE"
        CURRENT_HOST="${CONTROL_PLANE_HOSTS[$i]}"

        break

    fi

done

if [[ "$CURRENT_ROLE" == "UNKNOWN" ]]; then

    for ((i=1; i<=WORKER_COUNT; i++))
    do

        if [[ "$CURRENT_IP" == "${WORKER_IPS[$i]}" ]]; then

            CURRENT_ROLE="WORKER"
            CURRENT_HOST="${WORKER_HOSTS[$i]}"

            break

        fi

    done

fi

# ============================================================
# STEP 13 - Hostname
# ============================================================

echo
echo "Current role:"
echo "$CURRENT_ROLE"

if [[ "$CURRENT_ROLE" == "UNKNOWN" ]]; then

    echo
    echo "[WARNING] Current IP is not part of the cluster."
    echo "Hostname will not be changed."

else

    CURRENT_HOSTNAME=$(hostname)

    echo
    echo "Current hostname : $CURRENT_HOSTNAME"
    echo "Required hostname: $CURRENT_HOST"

    if [[ "$CURRENT_HOSTNAME" == "$CURRENT_HOST" ]]; then

        echo
        echo "[OK] Hostname is already correct."
        echo "[OK] Skipping hostname change."

    else

        echo
        echo "[INFO] Updating hostname..."

        hostnamectl set-hostname "$CURRENT_HOST"

        echo "[OK] Hostname changed to:"
        echo "$CURRENT_HOST"

    fi

fi

# ============================================================
# STEP 14 - Verify hostname resolution
# ============================================================

echo
echo "============================================================"
echo "             Hostname Resolution Test"
echo "============================================================"
echo

for ((i=1; i<=CONTROL_PLANE_COUNT; i++))
do

    HOST="${CONTROL_PLANE_HOSTS[$i]}"

    if getent ahostsv4 "$HOST" >/dev/null 2>&1; then

        echo "[OK] $HOST"

    else

        echo "[WARNING] Cannot resolve $HOST"

    fi

done

for ((i=1; i<=WORKER_COUNT; i++))
do

    HOST="${WORKER_HOSTS[$i]}"

    if getent ahostsv4 "$HOST" >/dev/null 2>&1; then

        echo "[OK] $HOST"

    else

        echo "[WARNING] Cannot resolve $HOST"

    fi

done

# ============================================================
# STEP 15 - Final output
# ============================================================

echo
echo "============================================================"
echo "        Kubernetes Cluster Configuration Completed"
echo "============================================================"
echo

echo "Configuration:"
echo "  $CONFIG_FILE"

echo
echo "Current Server:"
echo "  IP       : $CURRENT_IP"
echo "  Hostname : $(hostname)"
echo "  Role     : $CURRENT_ROLE"

echo
echo "Kubernetes entries in /etc/hosts:"
echo

grep -E \
    'k8s-controller|k8s-node' \
    "$HOSTS_FILE" || true

echo
echo "============================================================"
echo
echo "NEXT STEP:"
echo
echo "This configuration can now be used by the"
echo "Kubernetes installation scripts."
echo
echo "============================================================"
echo

