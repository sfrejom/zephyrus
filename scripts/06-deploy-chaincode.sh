#!/usr/bin/env bash
# ===========================================================================
# 06-deploy-chaincode.sh — Package, install, approve, and commit the
# swarm-management chaincode using the Fabric 2.5 lifecycle.
#
# Steps:
#   1. Package the Go chaincode (on UAV-2 CLI).
#   2. Install on peer0.org1 (UAV-2) and peer0.org2 (UAV-3).
#   3. Approve for both organisations.
#   4. Commit the chaincode definition.
#   5. Verify with querycommitted.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# ---------------------------------------------------------------------------
# Container-internal paths
# ---------------------------------------------------------------------------
BASE="/opt/gopath/src/github.com/hyperledger/fabric/peer"
C_ORDERER_CA="${BASE}/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/msp/tlscacerts/tlsca.${ORDERER_DOMAIN}-cert.pem"
CC_PKG_FILE="${CC_LABEL}.tar.gz"

# Org1 env for docker exec
ORG1_ENV=(
    "-e CORE_PEER_LOCALMSPID=SwarmOrg1MSP"
    "-e CORE_PEER_ADDRESS=${PEER0_ORG1_HOST}:${PEER0_ORG1_PORT}"
    "-e CORE_PEER_TLS_ENABLED=true"
    "-e CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls/ca.crt"
    "-e CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/users/Admin@${ORG1_DOMAIN}/msp"
)

# Org2 env for docker exec
ORG2_ENV=(
    "-e CORE_PEER_LOCALMSPID=SwarmOrg2MSP"
    "-e CORE_PEER_ADDRESS=${PEER0_ORG2_HOST}:${PEER0_ORG2_PORT}"
    "-e CORE_PEER_TLS_ENABLED=true"
    "-e CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/tls/ca.crt"
    "-e CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/users/Admin@${ORG2_DOMAIN}/msp"
)

# ===========================================================================
# Step 1: Package chaincode
# ===========================================================================
log_step "Step 1: Packaging chaincode '${CC_NAME}' v${CC_VERSION}"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode package \
        /tmp/${CC_PKG_FILE} \
        --path ${BASE}/chaincode/swarm-management \
        --lang golang \
        --label ${CC_LABEL} \
    2>&1
"
log_info "Chaincode packaged as ${CC_PKG_FILE}"

# Copy the package from UAV-2's CLI container to the host, then to UAV-3.
remote_exec "${UAV2_HOST}" "docker cp cli-org1:/tmp/${CC_PKG_FILE} /tmp/${CC_PKG_FILE}"

# Transfer package to UAV-3 via this admin machine (relay).
if command -v sshpass &>/dev/null; then
    sshpass -p "${SSH_PASS:-spilab}" scp ${SSH_OPTS} \
        "${SSH_USER}@${UAV2_HOST}:/tmp/${CC_PKG_FILE}" "/tmp/${CC_PKG_FILE}"
    sshpass -p "${SSH_PASS:-spilab}" scp ${SSH_OPTS} \
        "/tmp/${CC_PKG_FILE}" "${SSH_USER}@${UAV3_HOST}:/tmp/${CC_PKG_FILE}"
else
    scp ${SSH_OPTS} "${SSH_USER}@${UAV2_HOST}:/tmp/${CC_PKG_FILE}" "/tmp/${CC_PKG_FILE}"
    scp ${SSH_OPTS} "/tmp/${CC_PKG_FILE}" "${SSH_USER}@${UAV3_HOST}:/tmp/${CC_PKG_FILE}"
fi

remote_exec "${UAV3_HOST}" "docker cp /tmp/${CC_PKG_FILE} cli-org2:/tmp/${CC_PKG_FILE}"

# ===========================================================================
# Step 2: Install chaincode on both peers
# ===========================================================================
log_step "Step 2: Installing chaincode on peer0.org1 (UAV-2)"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode install \
        /tmp/${CC_PKG_FILE} \
    2>&1
"
log_info "Installed on peer0.org1"

log_step "Step 2b: Installing chaincode on peer0.org2 (UAV-3)"

remote_exec "${UAV3_HOST}" "
    docker exec ${ORG2_ENV[*]} cli-org2 peer lifecycle chaincode install \
        /tmp/${CC_PKG_FILE} \
    2>&1
"
log_info "Installed on peer0.org2"

# ===========================================================================
# Step 3: Query installed and extract package ID
# ===========================================================================
log_step "Step 3: Querying installed chaincode to get package ID"

QUERY_OUTPUT=$(remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode queryinstalled 2>&1
")
echo "$QUERY_OUTPUT"

# Extract package ID — format: "Package ID: swarm-management_1.0:abc123..., Label: swarm-management_1.0"
PACKAGE_ID=$(echo "$QUERY_OUTPUT" | grep -o "Package ID: ${CC_LABEL}:[a-f0-9]*" | sed 's/Package ID: //' | head -1)

if [[ -z "$PACKAGE_ID" ]]; then
    log_error "Could not extract package ID from queryinstalled output."
    log_error "Output was: ${QUERY_OUTPUT}"
    exit 1
fi

log_info "Package ID: ${PACKAGE_ID}"

# ===========================================================================
# Step 4: Approve for SwarmOrg1
# ===========================================================================
log_step "Step 4: Approving chaincode for SwarmOrg1"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode approveformyorg \
        --channelID ${CHANNEL_NAME} \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --package-id ${PACKAGE_ID} \
        --sequence ${CC_SEQUENCE} \
        --signature-policy \"${CC_ENDORSEMENT_POLICY}\" \
        -o ${ORDERER_HOST}:${ORDERER_PORT} \
        --tls --cafile ${C_ORDERER_CA} \
    2>&1
"
log_info "SwarmOrg1 approved chaincode."

# ===========================================================================
# Step 5: Approve for SwarmOrg2
# ===========================================================================
log_step "Step 5: Approving chaincode for SwarmOrg2"

remote_exec "${UAV3_HOST}" "
    docker exec ${ORG2_ENV[*]} cli-org2 peer lifecycle chaincode approveformyorg \
        --channelID ${CHANNEL_NAME} \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --package-id ${PACKAGE_ID} \
        --sequence ${CC_SEQUENCE} \
        --signature-policy \"${CC_ENDORSEMENT_POLICY}\" \
        -o ${ORDERER_HOST}:${ORDERER_PORT} \
        --tls --cafile ${C_ORDERER_CA} \
    2>&1
"
log_info "SwarmOrg2 approved chaincode."

# ===========================================================================
# Step 6: Check commit readiness
# ===========================================================================
log_step "Step 6: Checking commit readiness"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode checkcommitreadiness \
        --channelID ${CHANNEL_NAME} \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --sequence ${CC_SEQUENCE} \
        --signature-policy \"${CC_ENDORSEMENT_POLICY}\" \
        --output json \
    2>&1
"

# ===========================================================================
# Step 7: Commit chaincode definition (targets both peers)
# ===========================================================================
log_step "Step 7: Committing chaincode definition"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode commit \
        --channelID ${CHANNEL_NAME} \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --sequence ${CC_SEQUENCE} \
        --signature-policy \"${CC_ENDORSEMENT_POLICY}\" \
        -o ${ORDERER_HOST}:${ORDERER_PORT} \
        --tls --cafile ${C_ORDERER_CA} \
        --peerAddresses ${PEER0_ORG1_HOST}:${PEER0_ORG1_PORT} \
        --tlsRootCertFiles ${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls/ca.crt \
        --peerAddresses ${PEER0_ORG2_HOST}:${PEER0_ORG2_PORT} \
        --tlsRootCertFiles ${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/tls/ca.crt \
    2>&1
"
log_info "Chaincode definition committed."

# ===========================================================================
# Step 8: Verify
# ===========================================================================
log_step "Step 8: Verifying committed chaincode"

remote_exec "${UAV2_HOST}" "
    docker exec ${ORG1_ENV[*]} cli-org1 peer lifecycle chaincode querycommitted \
        --channelID ${CHANNEL_NAME} \
        --name ${CC_NAME} \
    2>&1
"

log_step "Chaincode '${CC_NAME}' v${CC_VERSION} deployed successfully"
log_info "Endorsement policy: ${CC_ENDORSEMENT_POLICY}"
log_info "Next step: 07-init-ledger.sh"
