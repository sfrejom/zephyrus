#!/usr/bin/env bash
# ===========================================================================
# 02-generate-channel-artifacts.sh — Generate channel artifacts with configtxgen.
#
# For Fabric 2.5 with the channel participation API (no system channel):
#   1. Generate the application channel genesis block (used with osnadmin).
#   2. Generate anchor peer update transactions for both orgs.
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
# 1. Application channel genesis block (for osnadmin channel join)
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
# 2. Anchor peer update for SwarmOrg1
# ---------------------------------------------------------------------------
log_info "Generating anchor peer update for SwarmOrg1 ..."
configtxgen \
    -profile SwarmChannel \
    -outputAnchorPeersUpdate ./channel-artifacts/SwarmOrg1MSPanchors.tx \
    -channelID "${CHANNEL_NAME}" \
    -asOrg SwarmOrg1MSP

if [[ ! -f channel-artifacts/SwarmOrg1MSPanchors.tx ]]; then
    log_warn "Anchor peer update tx for Org1 was not generated (may need configtxlator approach on Fabric 2.5+)."
else
    log_info "  -> channel-artifacts/SwarmOrg1MSPanchors.tx"
fi

# ---------------------------------------------------------------------------
# 3. Anchor peer update for SwarmOrg2
# ---------------------------------------------------------------------------
log_info "Generating anchor peer update for SwarmOrg2 ..."
configtxgen \
    -profile SwarmChannel \
    -outputAnchorPeersUpdate ./channel-artifacts/SwarmOrg2MSPanchors.tx \
    -channelID "${CHANNEL_NAME}" \
    -asOrg SwarmOrg2MSP

if [[ ! -f channel-artifacts/SwarmOrg2MSPanchors.tx ]]; then
    log_warn "Anchor peer update tx for Org2 was not generated (may need configtxlator approach on Fabric 2.5+)."
else
    log_info "  -> channel-artifacts/SwarmOrg2MSPanchors.tx"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "Channel artifacts generated"
ls -lh channel-artifacts/

log_info "Done. Next step: 03-distribute.sh"
