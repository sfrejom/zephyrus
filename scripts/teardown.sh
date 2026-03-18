#!/usr/bin/env bash
# ===========================================================================
# teardown.sh — Stop and clean up the Fabric network on all Raspberry Pis.
#
# Options:
#   --full   Also remove crypto material and channel artifacts locally.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

FULL_CLEAN=false
if [[ "${1:-}" == "--full" ]]; then
    FULL_CLEAN=true
fi

# ---------------------------------------------------------------------------
# Stop and remove containers on each node
# ---------------------------------------------------------------------------
stop_node() {
    local host="$1"
    local label="$2"
    local compose_file="$3"

    log_step "Stopping ${label} on ${host}"

    remote_exec "${host}" "
        cd ~/uav-fabric-network 2>/dev/null && \
        docker compose -f compose/${compose_file} --env-file compose/.env down -v --remove-orphans 2>&1 || true
    " || log_warn "Could not reach ${host} — skipping"

    # Clean up chaincode containers and images (name pattern: dev-peer0.*)
    remote_exec "${host}" "
        docker rm -f \$(docker ps -aq --filter 'name=dev-peer0') 2>/dev/null || true
        docker rmi -f \$(docker images -q --filter 'reference=dev-peer0*') 2>/dev/null || true
        docker volume prune -f 2>/dev/null || true
        docker network prune -f 2>/dev/null || true
    " 2>/dev/null || true
}

# Stop in reverse order.
stop_node "${UAV4_HOST}" "UAV-4 (Client)"   "docker-compose-uav4.yaml"
stop_node "${UAV3_HOST}" "UAV-3 (Peer Org2)" "docker-compose-uav3.yaml"
stop_node "${UAV2_HOST}" "UAV-2 (Peer Org1)" "docker-compose-uav2.yaml"
stop_node "${UAV1_HOST}" "UAV-1 (Orderer)"   "docker-compose-uav1.yaml"

# ---------------------------------------------------------------------------
# Full clean: remove generated artifacts locally
# ---------------------------------------------------------------------------
if [[ "$FULL_CLEAN" == "true" ]]; then
    log_step "Full cleanup: removing local generated artifacts"

    cd "${PROJECT_DIR}"

    for dir in organizations channel-artifacts; do
        if [[ -d "$dir" ]]; then
            log_info "Removing ${dir}/"
            rm -rf "$dir"
        fi
    done

    # Also clean up the remote project directories.
    log_step "Cleaning remote project directories"
    for host in "${UAV1_HOST}" "${UAV2_HOST}" "${UAV3_HOST}" "${UAV4_HOST}"; do
        remote_exec "${host}" "rm -rf ~/uav-fabric-network" 2>/dev/null || true
        log_info "Cleaned ${host}"
    done
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_step "Teardown complete"
if [[ "$FULL_CLEAN" == "true" ]]; then
    log_info "All containers, volumes, crypto material, and remote files removed."
else
    log_info "All containers and volumes removed. Crypto material preserved."
    log_info "Run with --full to also remove crypto material and remote files."
fi
