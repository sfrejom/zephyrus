#!/usr/bin/env bash
# ===========================================================================
# 04-start-network.sh — Start the Fabric network across all Raspberry Pis.
#
# Brings up Docker containers in order: UAV-1 (orderer/CA) first, then
# peers on UAV-2 and UAV-3, then the client CLI on UAV-4.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# ---------------------------------------------------------------------------
# Helper: start docker compose on a remote node and verify containers
# ---------------------------------------------------------------------------
start_node() {
    local host="$1"
    local label="$2"
    local compose_file="$3"
    local expected_containers="$4"  # comma-separated list

    log_step "Starting ${label} on ${host}"

    remote_exec "${host}" \
        "cd ~/uav-fabric-network && docker compose -f compose/${compose_file} --env-file compose/.env up -d 2>&1"

    # Wait for containers to come up.
    log_info "Waiting for containers to start ..."
    sleep 5

    # Verify containers are running.
    log_info "Checking containers on ${host}:"
    local running
    running=$(remote_exec "${host}" "docker ps --format '{{.Names}}\t{{.Status}}'" 2>/dev/null || true)
    echo "$running" | while read -r line; do
        log_info "  $line"
    done

    local all_ok=true
    IFS=',' read -ra CONTAINERS <<< "${expected_containers}"
    for container in "${CONTAINERS[@]}"; do
        container=$(echo "$container" | xargs)  # trim whitespace
        if echo "$running" | grep -q "$container"; then
            log_info "  ${container} — running"
        else
            log_error "  ${container} — NOT running"
            all_ok=false
        fi
    done

    if [[ "$all_ok" != "true" ]]; then
        log_error "Some containers on ${label} did not start. Check logs:"
        log_error "  ssh ${SSH_USER}@${host} 'cd ~/uav-fabric-network && docker compose -f compose/${compose_file} logs'"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Start nodes in order
# ---------------------------------------------------------------------------

# UAV-1: Orderer + CAs (must be up first)
start_node "${UAV1_HOST}" "UAV-1 (Orderer + CA)" "docker-compose-uav1.yaml" \
    "orderer.uav-network.local,ca.orderer.uav-network.local"

log_info "Giving orderer extra time to initialize ..."
sleep 5

# UAV-2: Peer Org1
start_node "${UAV2_HOST}" "UAV-2 (Peer Org1)" "docker-compose-uav2.yaml" \
    "peer0.org1.uav-network.local"

# UAV-3: Peer Org2
start_node "${UAV3_HOST}" "UAV-3 (Peer Org2)" "docker-compose-uav3.yaml" \
    "peer0.org2.uav-network.local"

# UAV-4: Client CLI
start_node "${UAV4_HOST}" "UAV-4 (Client)" "docker-compose-uav4.yaml" \
    "cli-agent"

# ---------------------------------------------------------------------------
# Final status
# ---------------------------------------------------------------------------
log_step "Network startup complete"
log_info "All Fabric containers are running across 4 Raspberry Pis."
log_info "Next step: 05-create-channel.sh"
