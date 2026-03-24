#!/usr/bin/env bash
# ===========================================================================
# status.sh — Quick health check of the Fabric network across all Pis.
#
# Checks:
#   - Docker container status on each node
#   - Orderer channel membership
#   - Peer channel membership
#   - Chaincode commit status
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

EXIT_CODE=0

# ---------------------------------------------------------------------------
# Check containers on a remote node
# ---------------------------------------------------------------------------
check_node() {
    local host="$1"
    local label="$2"

    log_step "${label} (${host})"

    local output
    output=$(remote_exec "${host}" \
        "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null) || {
        log_error "Cannot reach ${host}"
        EXIT_CODE=1
        return
    }

    if [[ -z "$output" ]] || [[ $(echo "$output" | wc -l) -le 1 ]]; then
        log_warn "No running containers on ${host}"
        EXIT_CODE=1
    else
        echo "$output"
    fi
}

# ---------------------------------------------------------------------------
# Container status
# ---------------------------------------------------------------------------
log_step "=== Docker Container Status ==="

check_node "${UAV1_HOST}" "UAV-1 (Orderer + CA)"
check_node "${UAV2_HOST}" "UAV-2 (Peer Org1)"
check_node "${UAV3_HOST}" "UAV-3 (Peer Org2)"
check_node "${UAV4_HOST}" "UAV-4 (Client)"

# ---------------------------------------------------------------------------
# Orderer channel list
# ---------------------------------------------------------------------------
log_step "=== Orderer Channel Membership ==="

OSNADMIN_TLS_CA="${PROJECT_DIR}/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/tls/ca.crt"
OSNADMIN_CLIENT_CERT="${PROJECT_DIR}/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/tls/server.crt"
OSNADMIN_CLIENT_KEY="${PROJECT_DIR}/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/tls/server.key"

remote_exec "${UAV1_HOST}" "
    export PATH=${FABRIC_BIN}:\$PATH
    osnadmin channel list \
        -o localhost:${ORDERER_ADMIN_PORT} \
        --ca-file ${OSNADMIN_TLS_CA} \
        --client-cert ${OSNADMIN_CLIENT_CERT} \
        --client-key ${OSNADMIN_CLIENT_KEY} \
    2>&1
" || { log_warn "Could not query orderer channels"; EXIT_CODE=1; }

# ---------------------------------------------------------------------------
# Peer channel list
# ---------------------------------------------------------------------------
BASE="/opt/gopath/src/github.com/hyperledger/fabric/peer"

log_step "=== Peer0.Org1 Channel Membership ==="

ORG1_ENV="-e CORE_PEER_LOCALMSPID=SwarmOrg1MSP -e CORE_PEER_ADDRESS=${PEER0_ORG1_HOST}:${PEER0_ORG1_PORT} -e CORE_PEER_TLS_ENABLED=true -e CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls/ca.crt -e CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/users/Admin@${ORG1_DOMAIN}/msp"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV} cli-org1 peer channel list 2>&1
" || { log_warn "Could not query peer0.org1 channels"; EXIT_CODE=1; }

log_step "=== Peer0.Org2 Channel Membership ==="

ORG2_ENV="-e CORE_PEER_LOCALMSPID=SwarmOrg2MSP -e CORE_PEER_ADDRESS=${PEER0_ORG2_HOST}:${PEER0_ORG2_PORT} -e CORE_PEER_TLS_ENABLED=true -e CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/tls/ca.crt -e CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/users/Admin@${ORG2_DOMAIN}/msp"

remote_exec "${UAV3_HOST}" "
    docker exec ${ORG2_ENV} cli-org2 peer channel list 2>&1
" || { log_warn "Could not query peer0.org2 channels"; EXIT_CODE=1; }

# ---------------------------------------------------------------------------
# Committed chaincode
# ---------------------------------------------------------------------------
log_step "=== Committed Chaincode ==="

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV} cli-org1 peer lifecycle chaincode querycommitted \
        --channelID ${CHANNEL_NAME} 2>&1
" || { log_warn "Could not query committed chaincode"; EXIT_CODE=1; }

# ---------------------------------------------------------------------------
# Quick Digital Twin query
# ---------------------------------------------------------------------------
log_step "=== Digital Twin Status (GetAllUAVs) ==="

DT_RESULT=$(remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV} cli-org1 peer chaincode query \
        -C ${CHANNEL_NAME} \
        -n ${CC_NAME} \
        -c '{\"function\":\"GetAllUAVs\",\"Args\":[]}' 2>&1
" || echo "QUERY_FAILED")

if [[ "$DT_RESULT" == "QUERY_FAILED" ]] || [[ "$DT_RESULT" == *"Error"* ]]; then
    log_warn "Could not query Digital Twin. Chaincode may not be initialized."
else
    # Pretty-print if jq is available.
    if command -v jq &>/dev/null; then
        echo "$DT_RESULT" | jq . 2>/dev/null || echo "$DT_RESULT"
    else
        echo "$DT_RESULT"
    fi

    UAV_COUNT=$(echo "$DT_RESULT" | grep -o '"uavId"' | wc -l || echo "0")
    log_info "Digital Twin contains ${UAV_COUNT} UAV(s)."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "=== Status Summary ==="

if [[ "$EXIT_CODE" -eq 0 ]]; then
    log_info "All checks passed. Network is healthy."
else
    log_warn "Some checks failed. Review the output above."
fi

exit $EXIT_CODE
