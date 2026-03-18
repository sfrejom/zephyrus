#!/usr/bin/env bash
# ===========================================================================
# 03-distribute.sh — Distribute project files to all Raspberry Pis via SCP.
#
# Copies crypto material, compose files, chaincode, channel artifacts, and
# config files to each node.  Uses sshpass if available; otherwise expects
# SSH key-based authentication.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log_step "Pre-flight checks"

if ! command -v sshpass &>/dev/null; then
    log_warn "sshpass is not installed. Using SSH key-based authentication."
    log_warn "If you haven't set up SSH keys, run on this machine:"
    log_warn "  ssh-keygen -t ed25519"
    log_warn "  ssh-copy-id ${SSH_USER}@uav-1.local"
    log_warn "  ssh-copy-id ${SSH_USER}@uav-2.local"
    log_warn "  ssh-copy-id ${SSH_USER}@uav-3.local"
    log_warn "  ssh-copy-id ${SSH_USER}@uav-4.local"
    echo ""
fi

# Verify required local directories exist.
for dir in organizations channel-artifacts compose config chaincode scripts; do
    if [[ ! -d "$dir" ]]; then
        log_error "Directory '${dir}' not found. Run the previous scripts first."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Helper: create remote directory and copy files
# ---------------------------------------------------------------------------
distribute_to() {
    local host="$1"
    local label="$2"
    shift 2

    log_step "Distributing to ${label} (${host})"

    # Create the base project directory on the remote Pi.
    remote_exec "${host}" "mkdir -p ~/uav-fabric-network"

    # Each remaining argument is "local_path:remote_subdir".
    for mapping in "$@"; do
        local_path="${mapping%%:*}"
        remote_subdir="${mapping##*:}"

        if [[ ! -e "${local_path}" ]]; then
            log_warn "  Skipping ${local_path} — does not exist locally"
            continue
        fi

        remote_exec "${host}" "mkdir -p ~/uav-fabric-network/${remote_subdir}"
        log_info "  ${local_path} -> ~/uav-fabric-network/${remote_subdir}"
        remote_copy "${local_path}" "${host}" "~/uav-fabric-network/${remote_subdir}/"
    done
}

# ---------------------------------------------------------------------------
# Copy Fabric config files (core.yaml, orderer.yaml) into config/
# ---------------------------------------------------------------------------
log_step "Copying Fabric sample config files into project config/"

FABRIC_SAMPLE_CFG="$HOME/go/src/github.com/spilab/fabric-samples/config"
for cfg_file in core.yaml orderer.yaml; do
    if [[ -f "${FABRIC_SAMPLE_CFG}/${cfg_file}" ]] && [[ ! -f "config/${cfg_file}" ]]; then
        cp "${FABRIC_SAMPLE_CFG}/${cfg_file}" "config/${cfg_file}"
        log_info "Copied ${cfg_file} from fabric-samples/config"
    fi
done

# ---------------------------------------------------------------------------
# UAV-1: Orderer + CA
#   - organizations/ (all crypto — orderer needs peer TLS CA certs too)
#   - channel-artifacts/ (genesis block for osnadmin)
#   - compose/.env + docker-compose-uav1.yaml
#   - config/ (orderer.yaml)
#   - scripts/ (for convenience)
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
#   - organizations/ (full tree — peer needs orderer TLS CA for channel join)
#   - channel-artifacts/ (channel block for peer channel join)
#   - compose/.env + docker-compose-uav2.yaml
#   - chaincode/ (for packaging)
#   - config/ (core.yaml)
#   - scripts/
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
#   - Same as UAV-2, with docker-compose-uav3.yaml
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
#   - organizations/ (needs MSP for SDK/CLI identity)
#   - channel-artifacts/ (for reference)
#   - compose/.env + docker-compose-uav4.yaml
#   - config/ (core.yaml for CLI)
#   - scripts/
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
log_info "All files have been copied to the Raspberry Pis."
log_info "Next step: 04-start-network.sh"
