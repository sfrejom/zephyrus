#!/usr/bin/env bash
# ===========================================================================
# 07-init-ledger.sh — Initialize the Digital Twin ledger with sample UAV data.
#
# Invokes the InitLedger chaincode function and verifies with GetAllUAVs.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# ---------------------------------------------------------------------------
# Container-internal paths
# ---------------------------------------------------------------------------
BASE="/opt/gopath/src/github.com/hyperledger/fabric/peer"
C_ORDERER_CA="${BASE}/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/msp/tlscacerts/tlsca.${ORDERER_DOMAIN}-cert.pem"

# Org1 env
ORG1_ENV=(
    "-e CORE_PEER_LOCALMSPID=SwarmOrg1MSP"
    "-e CORE_PEER_ADDRESS=${PEER0_ORG1_HOST}:${PEER0_ORG1_PORT}"
    "-e CORE_PEER_TLS_ENABLED=true"
    "-e CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls/ca.crt"
    "-e CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/users/Admin@${ORG1_DOMAIN}/msp"
)

# Both peers for endorsement (AND policy).
PEER_CONN_ARGS=(
    "--peerAddresses ${PEER0_ORG1_HOST}:${PEER0_ORG1_PORT}"
    "--tlsRootCertFiles ${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls/ca.crt"
    "--peerAddresses ${PEER0_ORG2_HOST}:${PEER0_ORG2_PORT}"
    "--tlsRootCertFiles ${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/tls/ca.crt"
)

# ===========================================================================
# Step 1: Invoke InitLedger
# ===========================================================================
log_step "Invoking InitLedger to seed Digital Twin state"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer chaincode invoke \
        -o ${ORDERER_HOST}:${ORDERER_PORT} \
        --tls --cafile ${C_ORDERER_CA} \
        -C ${CHANNEL_NAME} \
        -n ${CC_NAME} \
        ${PEER_CONN_ARGS[*]} \
        -c '{\"function\":\"InitLedger\",\"Args\":[]}' \
        --waitForEvent \
    2>&1
"

log_info "InitLedger invoked. Waiting for block propagation ..."
sleep 3

# ===========================================================================
# Step 2: Verify by querying GetAllUAVs
# ===========================================================================
log_step "Querying GetAllUAVs to verify initialization"

RESULT=$(remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer chaincode query \
        -C ${CHANNEL_NAME} \
        -n ${CC_NAME} \
        -c '{\"function\":\"GetAllUAVs\",\"Args\":[]}' \
    2>&1
")

echo "$RESULT"

# Quick validation — check that we got 4 UAVs.
UAV_COUNT=$(echo "$RESULT" | grep -o '"uavId"' | wc -l || echo "0")
if [[ "$UAV_COUNT" -ge 4 ]]; then
    log_info "Digital Twin initialized successfully with ${UAV_COUNT} UAVs."
else
    log_warn "Expected at least 4 UAVs but found ${UAV_COUNT}. Check the output above."
fi

# ===========================================================================
# Step 3: Query a single UAV to double-check
# ===========================================================================
log_step "Querying individual UAV state (UAV-001)"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer chaincode query \
        -C ${CHANNEL_NAME} \
        -n ${CC_NAME} \
        -c '{\"function\":\"GetUAVState\",\"Args\":[\"UAV-001\"]}' \
    2>&1
"

# ===========================================================================
# Done
# ===========================================================================
log_step "Ledger initialization complete"
log_info "The UAV Swarm Digital Twin is operational."
log_info ""
log_info "Useful commands (run inside a CLI container):"
log_info "  Query all UAVs:        peer chaincode query -C ${CHANNEL_NAME} -n ${CC_NAME} -c '{\"function\":\"GetAllUAVs\",\"Args\":[]}'"
log_info "  Update telemetry:      peer chaincode invoke ... -c '{\"function\":\"UpdateTelemetry\",\"Args\":[\"UAV-002\",\"85\",\"45\",\"50\",\"30\",\"90\",\"40.42\",\"-3.71\",\"55\"]}'"
log_info "  Check depletion:       peer chaincode invoke ... -c '{\"function\":\"CheckDepletionThreshold\",\"Args\":[\"UAV-002\",\"20\"]}'"
log_info "  Initiate handover:     peer chaincode invoke ... -c '{\"function\":\"InitiateHandover\",\"Args\":[\"UAV-002\"]}'"
