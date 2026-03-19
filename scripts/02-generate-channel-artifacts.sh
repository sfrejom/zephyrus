#!/usr/bin/env bash
# ===========================================================================
# 02-generate-channel-artifacts.sh — Generate channel artifacts with configtxgen.
#
# For Fabric 2.5 with the channel participation API (no system channel):
#   - Generate the application channel genesis block (used with osnadmin).
#
# Anchor peers are already defined in configtx.yaml within each org's
# AnchorPeers section, so they are embedded in the genesis block
# automatically. No separate anchor peer update transactions are needed.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "${PROJECT_DIR}"

log_step "Generating channel artifacts"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if ! command -v configtxgen &>/dev/null; then
    log_error "configtxgen not found in PATH."
    exit 1
fi

if [[ ! -f config/configtx.yaml ]]; then
    log_error "config/configtx.yaml not found."
    exit 1
fi

if [[ ! -d organizations ]]; then
    log_error "organizations/ directory not found. Run 01-generate-crypto.sh first."
    exit 1
fi

export FABRIC_CFG_PATH="${PROJECT_DIR}/config"

# ---------------------------------------------------------------------------
# Clean & create output directory
# ---------------------------------------------------------------------------
rm -rf channel-artifacts
mkdir -p channel-artifacts

# ---------------------------------------------------------------------------
# Generate application channel genesis block (for osnadmin channel join)
#
# This block contains:
#   - Orderer configuration (Raft, single consenter)
#   - Both peer organizations (SwarmOrg1, SwarmOrg2)
#   - Anchor peers for both orgs (from configtx.yaml AnchorPeers sections)
#   - Endorsement policy AND(SwarmOrg1MSP.peer, SwarmOrg2MSP.peer)
# ---------------------------------------------------------------------------
log_info "Generating channel genesis block for '${CHANNEL_NAME}' ..."
configtxgen \
    -profile SwarmChannel \
    -outputBlock ./channel-artifacts/${CHANNEL_NAME}.block \
    -channelID "${CHANNEL_NAME}"

if [[ ! -f channel-artifacts/${CHANNEL_NAME}.block ]]; then
    log_error "Failed to generate channel genesis block."
    exit 1
fi
log_info "  -> channel-artifacts/${CHANNEL_NAME}.block"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "Channel artifacts generated"
ls -lh channel-artifacts/

log_info "Note: Anchor peers are already included in the genesis block"
log_info "      (defined in configtx.yaml AnchorPeers sections)."
log_info ""
log_info "Done. Next step: 03-distribute.sh"
