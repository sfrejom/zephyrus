#!/usr/bin/env bash
# ===========================================================================
# 00-resolve-hosts.sh — Resolve mDNS hostnames to IP addresses.
#
# Resolves uav-{1..4}.local via avahi or getent, writes the IPs into
# compose/.env, and verifies reachability with ping.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_step "Resolving Raspberry Pi hostnames to IP addresses"

# ---------------------------------------------------------------------------
# resolve_host <hostname> — returns the first IPv4 address
# ---------------------------------------------------------------------------
resolve_host() {
    local host="$1"
    local ip=""

    # Try avahi first (common on Raspberry Pi OS).
    if command -v avahi-resolve-host-name &>/dev/null; then
        ip=$(avahi-resolve-host-name -4 "${host}" 2>/dev/null | awk '{print $2}' || true)
    fi

    # Fallback to getent.
    if [[ -z "$ip" ]] && command -v getent &>/dev/null; then
        ip=$(getent hosts "${host}" 2>/dev/null | awk '{print $1}' || true)
    fi

    # Fallback to ping-based resolution.
    if [[ -z "$ip" ]]; then
        ip=$(ping -c1 -W2 "${host}" 2>/dev/null | head -1 | grep -oP '\(\K[0-9.]+' || true)
    fi

    echo "${ip}"
}

# ---------------------------------------------------------------------------
# Resolve each UAV host
# ---------------------------------------------------------------------------
declare -A NODE_IPS
HOSTS=("UAV1:${UAV1_HOST}" "UAV2:${UAV2_HOST}" "UAV3:${UAV3_HOST}" "UAV4:${UAV4_HOST}")
ALL_OK=true

for entry in "${HOSTS[@]}"; do
    label="${entry%%:*}"
    hostname="${entry##*:}"

    log_info "Resolving ${hostname} ..."
    ip=$(resolve_host "${hostname}")

    if [[ -z "$ip" ]]; then
        log_error "Could not resolve ${hostname}"
        ALL_OK=false
    else
        NODE_IPS["${label}"]="$ip"
        log_info "${hostname} -> ${ip}"
    fi
done

if [[ "$ALL_OK" != "true" ]]; then
    log_error "One or more hosts could not be resolved. Aborting."
    log_warn "Make sure avahi-daemon is running on all Pis and this machine."
    log_warn "Alternatively, set IPs manually in compose/.env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify reachability
# ---------------------------------------------------------------------------
log_step "Verifying host reachability"

for entry in "${HOSTS[@]}"; do
    label="${entry%%:*}"
    hostname="${entry##*:}"
    ip="${NODE_IPS[$label]}"

    if ping -c1 -W3 "${ip}" &>/dev/null; then
        log_info "${label} (${ip}) — reachable"
    else
        log_error "${label} (${ip}) — NOT reachable"
        ALL_OK=false
    fi
done

if [[ "$ALL_OK" != "true" ]]; then
    log_error "One or more hosts are unreachable. Check network connectivity."
    exit 1
fi

# ---------------------------------------------------------------------------
# Write IPs to compose/.env
# ---------------------------------------------------------------------------
log_step "Writing IPs to compose/.env"

COMPOSE_ENV_FILE="${PROJECT_DIR}/compose/.env"
mkdir -p "$(dirname "${COMPOSE_ENV_FILE}")"

# If the file already exists, update IP lines; otherwise create it.
if [[ -f "${COMPOSE_ENV_FILE}" ]]; then
    # Remove existing UAV*_IP lines before appending.
    sed -i '/^UAV[1-4]_IP=/d' "${COMPOSE_ENV_FILE}"
fi

cat >> "${COMPOSE_ENV_FILE}" <<EOF
UAV1_IP=${NODE_IPS[UAV1]}
UAV2_IP=${NODE_IPS[UAV2]}
UAV3_IP=${NODE_IPS[UAV3]}
UAV4_IP=${NODE_IPS[UAV4]}
EOF

log_info "Updated ${COMPOSE_ENV_FILE}:"
grep '^UAV[1-4]_IP=' "${COMPOSE_ENV_FILE}"

# ---------------------------------------------------------------------------
# Optionally update /etc/hosts (requires sudo)
# ---------------------------------------------------------------------------
log_step "Updating /etc/hosts (optional, requires sudo)"

HOSTS_ENTRIES=(
    "${NODE_IPS[UAV1]}  uav-1.local orderer.uav-network.local ca.orderer.uav-network.local ca.org1.uav-network.local ca.org2.uav-network.local"
    "${NODE_IPS[UAV2]}  uav-2.local peer0.org1.uav-network.local"
    "${NODE_IPS[UAV3]}  uav-3.local peer0.org2.uav-network.local"
    "${NODE_IPS[UAV4]}  uav-4.local"
)

UPDATE_HOSTS=false
for entry in "${HOSTS_ENTRIES[@]}"; do
    host_ip=$(echo "$entry" | awk '{print $1}')
    first_name=$(echo "$entry" | awk '{print $2}')
    if ! grep -q "${first_name}" /etc/hosts 2>/dev/null; then
        UPDATE_HOSTS=true
        break
    fi
done

if [[ "$UPDATE_HOSTS" == "true" ]]; then
    log_warn "/etc/hosts is missing UAV entries. Attempting to add them (requires sudo)."
    for entry in "${HOSTS_ENTRIES[@]}"; do
        first_name=$(echo "$entry" | awk '{print $2}')
        # Remove stale lines for this host.
        sudo sed -i "/${first_name}/d" /etc/hosts 2>/dev/null || true
        echo "$entry" | sudo tee -a /etc/hosts >/dev/null 2>/dev/null || {
            log_warn "Could not write to /etc/hosts. You may need to add entries manually:"
            for e in "${HOSTS_ENTRIES[@]}"; do
                echo "  $e"
            done
            break
        }
    done
    log_info "/etc/hosts updated."
else
    log_info "/etc/hosts already contains UAV entries — no changes needed."
fi

log_info "Host resolution complete."
