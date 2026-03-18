#!/usr/bin/env bash
# ===========================================================================
# 01-generate-crypto.sh — Generate cryptographic material with cryptogen.
#
# Run this from the project root (UAV-1 or the admin workstation).  It
# produces the organizations/ directory tree containing MSP and TLS
# certificates for all orgs, orderers, and peers.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "${PROJECT_DIR}"

log_step "Generating cryptographic material"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v cryptogen &>/dev/null; then
    log_error "cryptogen not found in PATH. Ensure Fabric binaries are installed."
    log_error "Expected location: ${FABRIC_BIN}/cryptogen"
    exit 1
fi

if [[ ! -f config/crypto-config.yaml ]]; then
    log_error "config/crypto-config.yaml not found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Clean previous output
# ---------------------------------------------------------------------------
if [[ -d organizations ]]; then
    log_warn "Removing existing organizations/ directory"
    rm -rf organizations
fi

# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------
log_info "Running cryptogen generate ..."
cryptogen generate --config=config/crypto-config.yaml --output=organizations

# ---------------------------------------------------------------------------
# Verify output structure
# ---------------------------------------------------------------------------
log_step "Verifying generated material"

CHECKS=(
    "organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/msp"
    "organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/tls"
    "organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/msp"
    "organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls"
    "organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/msp"
    "organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/tls"
    "organizations/ordererOrganizations/${ORDERER_DOMAIN}/users/Admin@${ORDERER_DOMAIN}/msp"
    "organizations/peerOrganizations/${ORG1_DOMAIN}/users/Admin@${ORG1_DOMAIN}/msp"
    "organizations/peerOrganizations/${ORG2_DOMAIN}/users/Admin@${ORG2_DOMAIN}/msp"
)

ALL_OK=true
for dir in "${CHECKS[@]}"; do
    if [[ -d "$dir" ]]; then
        log_info "  OK  $dir"
    else
        log_error "  MISSING  $dir"
        ALL_OK=false
    fi
done

if [[ "$ALL_OK" != "true" ]]; then
    log_error "Crypto generation produced an incomplete structure."
    exit 1
fi

log_info "Crypto material generated successfully in organizations/"
