#!/usr/bin/env bash
# ===========================================================================
# 05-create-channel.sh — Create the swarm-management channel.
#
# 1. Use osnadmin on UAV-1 to join the orderer to the channel.
# 2. Join peer0.org1 on UAV-2 via the CLI container.
# 3. Join peer0.org2 on UAV-3 via the CLI container.
#
# Note: Anchor peers are already included in the genesis block
# (defined in configtx.yaml AnchorPeers sections), so no separate
# anchor peer update transaction is needed.
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

CHANNEL_BLOCK="channel-artifacts/${CHANNEL_NAME}.block"

# ---------------------------------------------------------------------------
# Paths inside containers (volumes are mounted under /opt/gopath/src/...)
# ---------------------------------------------------------------------------
# The CLI containers mount the project at a known base path.
BASE="/opt/gopath/src/github.com/hyperledger/fabric/peer"
C_ORDERER_CA="${BASE}/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/msp/tlscacerts/tlsca.${ORDERER_DOMAIN}-cert.pem"
C_CHANNEL_BLOCK="${BASE}/${CHANNEL_BLOCK}"

# Org1 CLI env (set inside docker exec)
ORG1_CLI_ENV=(
    "CORE_PEER_LOCALMSPID=SwarmOrg1MSP"
    "CORE_PEER_ADDRESS=${PEER0_ORG1_HOST}:${PEER0_ORG1_PORT}"
    "CORE_PEER_TLS_ENABLED=true"
    "CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/peers/${PEER0_ORG1_HOST}/tls/ca.crt"
    "CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG1_DOMAIN}/users/Admin@${ORG1_DOMAIN}/msp"
)

# Org2 CLI env
ORG2_CLI_ENV=(
    "CORE_PEER_LOCALMSPID=SwarmOrg2MSP"
    "CORE_PEER_ADDRESS=${PEER0_ORG2_HOST}:${PEER0_ORG2_PORT}"
    "CORE_PEER_TLS_ENABLED=true"
    "CORE_PEER_TLS_ROOTCERT_FILE=${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/peers/${PEER0_ORG2_HOST}/tls/ca.crt"
    "CORE_PEER_MSPCONFIGPATH=${BASE}/organizations/peerOrganizations/${ORG2_DOMAIN}/users/Admin@${ORG2_DOMAIN}/msp"
)

# ---------------------------------------------------------------------------
# Step 1: osnadmin — join the orderer to the channel
# ---------------------------------------------------------------------------
log_step "Step 1: Joining orderer to channel '${CHANNEL_NAME}' via osnadmin"

# Paths on UAV-1 filesystem (not container — osnadmin runs natively or via
# docker exec on the orderer container).  We run it from the host.
OSNADMIN_TLS_CA="\$HOME/uav-fabric-network/organizations/ordererOrganizations/${ORDERER_DOMAIN}/tlsca/tlsca.${ORDERER_DOMAIN}-cert.pem"
OSNADMIN_CLIENT_CERT="\$HOME/uav-fabric-network/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/tls/server.crt"
OSNADMIN_CLIENT_KEY="\$HOME/uav-fabric-network/organizations/ordererOrganizations/${ORDERER_DOMAIN}/orderers/${ORDERER_HOST}/tls/server.key"
OSNADMIN_BLOCK="\$HOME/uav-fabric-network/${CHANNEL_BLOCK}"

remote_exec "${UAV1_HOST}" "
    export PATH=\$HOME/go/src/github.com/spilab/fabric-samples/bin:\$PATH
    osnadmin channel join \
        --channelID ${CHANNEL_NAME} \
        --config-block ${OSNADMIN_BLOCK} \
        -o localhost:${ORDERER_ADMIN_PORT} \
        --ca-file ${OSNADMIN_TLS_CA} \
        --client-cert ${OSNADMIN_CLIENT_CERT} \
        --client-key ${OSNADMIN_CLIENT_KEY}
"

log_info "Orderer joined channel '${CHANNEL_NAME}'."

# Verify.
log_info "Listing channels on orderer ..."
remote_exec "${UAV1_HOST}" "
    export PATH=\$HOME/go/src/github.com/spilab/fabric-samples/bin:\$PATH
    osnadmin channel list \
        -o localhost:${ORDERER_ADMIN_PORT} \
        --ca-file ${OSNADMIN_TLS_CA} \
        --client-cert ${OSNADMIN_CLIENT_CERT} \
        --client-key ${OSNADMIN_CLIENT_KEY}
"

sleep 3

# ---------------------------------------------------------------------------
# Step 2: Join peer0.org1 to the channel (UAV-2)
# ---------------------------------------------------------------------------
log_step "Step 2: Joining peer0.org1 to channel '${CHANNEL_NAME}'"

# First, fetch the genesis block from the orderer into the CLI container.
ENV_ARGS=""
for e in "${ORG1_CLI_ENV[@]}"; do ENV_ARGS+=" -e $e"; done

remote_exec "${UAV2_HOST}" "
    docker exec ${ENV_ARGS} cli-org1 peer channel fetch 0 \
        ${C_CHANNEL_BLOCK} \
        -o ${ORDERER_HOST}:${ORDERER_PORT} \
        -c ${CHANNEL_NAME} \
        --tls --cafile ${C_ORDERER_CA} \
    2>&1 || true
"

remote_exec "${UAV2_HOST}" "
    docker exec ${ENV_ARGS} cli-org1 peer channel join \
        -b ${C_CHANNEL_BLOCK} \
    2>&1
"

log_info "peer0.org1 joined channel '${CHANNEL_NAME}'."

# Verify.
remote_exec "${UAV2_HOST}" "
    docker exec ${ENV_ARGS} cli-org1 peer channel list 2>&1
"

sleep 2

# ---------------------------------------------------------------------------
# Step 3: Join peer0.org2 to the channel (UAV-3)
# ---------------------------------------------------------------------------
log_step "Step 3: Joining peer0.org2 to channel '${CHANNEL_NAME}'"

ENV_ARGS=""
for e in "${ORG2_CLI_ENV[@]}"; do ENV_ARGS+=" -e $e"; done

remote_exec "${UAV3_HOST}" "
    docker exec ${ENV_ARGS} cli-org2 peer channel fetch 0 \
        ${C_CHANNEL_BLOCK} \
        -o ${ORDERER_HOST}:${ORDERER_PORT} \
        -c ${CHANNEL_NAME} \
        --tls --cafile ${C_ORDERER_CA} \
    2>&1 || true
"

remote_exec "${UAV3_HOST}" "
    docker exec ${ENV_ARGS} cli-org2 peer channel join \
        -b ${C_CHANNEL_BLOCK} \
    2>&1
"

log_info "peer0.org2 joined channel '${CHANNEL_NAME}'."

remote_exec "${UAV3_HOST}" "
    docker exec ${ENV_ARGS} cli-org2 peer channel list 2>&1
"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_step "Channel '${CHANNEL_NAME}' created and all peers joined"
log_info "Anchor peers were already included in the genesis block (configtx.yaml)."
log_info "Next step: 06-deploy-chaincode.sh"
