#!/usr/bin/env bash
# ===========================================================================
# 03-distribute.sh — Distribute project files to all Raspberry Pis via rsync.
#
# Uses rsync for reliable recursive copy with built-in verification.
# Falls back to scp if rsync is not available on the remote host.
# After each transfer, verifies the file count matches.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "${PROJECT_DIR}"

REMOTE_BASE="${PROJECT_DIR}"   # /home/spilab/uav-fabric-network

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log_step "Pre-flight checks"

# Check rsync availability (local).
if ! command -v rsync &>/dev/null; then
    log_error "rsync is not installed locally. Install with: sudo apt-get install -y rsync"
    exit 1
fi

if ! command -v sshpass &>/dev/null; then
    log_warn "sshpass is not installed. Using SSH key-based authentication."
    log_warn "If prompted for passwords repeatedly, install sshpass:"
    log_warn "  sudo apt-get install -y sshpass"
    echo ""
fi

# Verify required local directories exist.
for dir in organizations channel-artifacts compose config chaincode scripts; do
    if [[ ! -d "$dir" ]]; then
        log_error "Directory '${dir}' not found. Run the previous scripts first."
        exit 1
    fi
done

# Count local files in organizations/ for verification later.
LOCAL_ORG_COUNT=$(find organizations -type f | wc -l)
log_info "Local organizations/ has ${LOCAL_ORG_COUNT} files."

# ---------------------------------------------------------------------------
# Helper: rsync wrapper with sshpass support
# ---------------------------------------------------------------------------
do_rsync() {
    local src="$1" host="$2" dest="$3"
    local rsync_ssh="ssh ${SSH_OPTS}"

    if command -v sshpass &>/dev/null; then
        rsync_ssh="sshpass -p ${SSH_PASS:-spilab} ssh ${SSH_OPTS}"
    fi

    rsync -az --no-group --no-owner --delete -e "${rsync_ssh}" "${src}" "${SSH_USER}@${host}:${dest}"
}

# ---------------------------------------------------------------------------
# Helper: distribute to a single node with verification
# ---------------------------------------------------------------------------
distribute_to() {
    local host="$1"
    local label="$2"
    shift 2

    log_step "Distributing to ${label} (${host})"

    # Ensure rsync is available on remote host.
    if ! remote_exec "${host}" "command -v rsync" &>/dev/null; then
        log_warn "rsync not found on ${host}. Installing..."
        remote_exec "${host}" "sudo apt-get install -y rsync" >/dev/null 2>&1 || true
    fi

    # Clean up any directories with broken permissions (e.g. from Docker or previous partial copies).
    remote_exec "${host}" "sudo chown -R ${SSH_USER}:${SSH_USER} ${REMOTE_BASE}/organizations 2>/dev/null; true"

    # Create the base project directory on the remote Pi.
    remote_exec "${host}" "mkdir -p ${REMOTE_BASE}"

    # Each remaining argument is "local_path:remote_subdir".
    for mapping in "$@"; do
        local_path="${mapping%%:*}"
        remote_subdir="${mapping##*:}"

        if [[ ! -e "${local_path}" ]]; then
            log_warn "  Skipping ${local_path} — does not exist locally"
            continue
        fi

        # Ensure remote subdir exists.
        if [[ "${remote_subdir}" != "." ]]; then
            remote_exec "${host}" "mkdir -p ${REMOTE_BASE}/${remote_subdir}"
        fi

        # Determine source and destination for rsync.
        local dest_path="${REMOTE_BASE}/${remote_subdir}/"
        if [[ -d "${local_path}" ]]; then
            # Directory: trailing slash on source means "copy contents into dest"
            do_rsync "${local_path}/" "${host}" "${dest_path}${local_path}/"
            log_info "  ${local_path}/ -> ${REMOTE_BASE}/${remote_subdir}/${local_path}/"
        else
            # Single file
            do_rsync "${local_path}" "${host}" "${dest_path}"
            log_info "  ${local_path} -> ${dest_path}"
        fi
    done

    # --- Verify organizations/ file count ---
    local remote_count
    remote_count=$(remote_exec "${host}" "find ${REMOTE_BASE}/organizations -type f 2>/dev/null | wc -l" || echo "0")
    remote_count=$(echo "${remote_count}" | tr -d '[:space:]')

    if [[ "${remote_count}" -eq "${LOCAL_ORG_COUNT}" ]]; then
        log_info "  Verified: organizations/ has ${remote_count}/${LOCAL_ORG_COUNT} files."
    else
        log_error "  MISMATCH on ${host}: organizations/ has ${remote_count} files, expected ${LOCAL_ORG_COUNT}."
        log_error "  Re-run this script or manually fix with:"
        log_error "    rsync -avz ${PROJECT_DIR}/organizations/ ${SSH_USER}@${host}:${REMOTE_BASE}/organizations/"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Copy Fabric config files (core.yaml, orderer.yaml) into config/
# ---------------------------------------------------------------------------
log_step "Copying Fabric sample config files into project config/"

FABRIC_SAMPLE_CFG="${SPILAB_HOME}/go/src/github.com/spilab/fabric-samples/config"
for cfg_file in core.yaml orderer.yaml; do
    if [[ -f "${FABRIC_SAMPLE_CFG}/${cfg_file}" ]]; then
        cp "${FABRIC_SAMPLE_CFG}/${cfg_file}" "config/${cfg_file}"
        log_info "Copied ${cfg_file} from fabric-samples/config"
    fi
done

# ---------------------------------------------------------------------------
# Ensure chaincode dependencies are resolved (go.sum)
# ---------------------------------------------------------------------------
log_step "Resolving chaincode Go dependencies"
if command -v go &>/dev/null; then
    (cd "${PROJECT_DIR}/chaincode/swarm-management" && go mod tidy 2>&1)
    log_info "go.sum generated for chaincode."
else
    if [[ ! -f "${PROJECT_DIR}/chaincode/swarm-management/go.sum" ]]; then
        log_warn "Go is not installed and go.sum is missing. Chaincode installation may fail."
    fi
fi

# ---------------------------------------------------------------------------
# UAV-1: Orderer + CA
# ---------------------------------------------------------------------------
distribute_to "${UAV1_HOST}" "UAV-1 (Orderer)" \
    "organizations:." \
    "channel-artifacts:." \
    "compose/.env:compose" \
    "compose/docker-compose-uav1.yaml:compose" \
    "config:." \
    "scripts:."

# ---------------------------------------------------------------------------
# UAV-2: Peer Org1
# ---------------------------------------------------------------------------
distribute_to "${UAV2_HOST}" "UAV-2 (Peer Org1)" \
    "organizations:." \
    "channel-artifacts:." \
    "compose/.env:compose" \
    "compose/docker-compose-uav2.yaml:compose" \
    "chaincode:." \
    "config:." \
    "scripts:."

# ---------------------------------------------------------------------------
# UAV-3: Peer Org2
# ---------------------------------------------------------------------------
distribute_to "${UAV3_HOST}" "UAV-3 (Peer Org2)" \
    "organizations:." \
    "channel-artifacts:." \
    "compose/.env:compose" \
    "compose/docker-compose-uav3.yaml:compose" \
    "chaincode:." \
    "config:." \
    "scripts:."

# ---------------------------------------------------------------------------
# UAV-4: Client / Swarm Agent
# ---------------------------------------------------------------------------
distribute_to "${UAV4_HOST}" "UAV-4 (Client)" \
    "organizations:." \
    "channel-artifacts:." \
    "compose/.env:compose" \
    "compose/docker-compose-uav4.yaml:compose" \
    "config:." \
    "scripts:."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_step "Distribution complete"
log_info "All files verified on all Raspberry Pis."
log_info "Next step: 04-start-network.sh"
