#!/usr/bin/env bash
# ===========================================================================
# env.sh — Shared environment variables for the UAV Swarm Fabric network.
# Source this file from every other script:  source "$(dirname "$0")/env.sh"
# ===========================================================================

# ---------------------------------------------------------------------------
# Paths — use explicit /home/spilab to avoid $HOME resolving to /root
# when the script runs via SSH or sudo.
# ---------------------------------------------------------------------------
export SPILAB_HOME="/home/spilab"
export PROJECT_DIR="/home/uav-fabric-network"
export FABRIC_BIN="${SPILAB_HOME}/go/src/github.com/spilab/fabric-samples/bin"
export FABRIC_CFG_PATH="${PROJECT_DIR}/config"
export PATH="$FABRIC_BIN:$PATH"

# ---------------------------------------------------------------------------
# Network naming
# ---------------------------------------------------------------------------
export CHANNEL_NAME="swarm-management"
export ORDERER_DOMAIN="uav-network.local"
export ORG1_DOMAIN="org1.uav-network.local"
export ORG2_DOMAIN="org2.uav-network.local"
export ORDERER_HOST="orderer.${ORDERER_DOMAIN}"
export PEER0_ORG1_HOST="peer0.${ORG1_DOMAIN}"
export PEER0_ORG2_HOST="peer0.${ORG2_DOMAIN}"

# ---------------------------------------------------------------------------
# Chaincode
# ---------------------------------------------------------------------------
export CC_NAME="swarm-management"
export CC_VERSION="1.0"
export CC_SEQUENCE=1
export CC_SRC_PATH="$PROJECT_DIR/chaincode/swarm-management"
export CC_LABEL="${CC_NAME}_${CC_VERSION}"
export CC_ENDORSEMENT_POLICY="AND('SwarmOrg1MSP.peer','SwarmOrg2MSP.peer')"

# ---------------------------------------------------------------------------
# Raspberry Pi hosts (mDNS names — resolved to IPs by 00-resolve-hosts.sh)
# ---------------------------------------------------------------------------
export UAV1_HOST="uav-1.local"
export UAV2_HOST="uav-2.local"
export UAV3_HOST="uav-3.local"
export UAV4_HOST="uav-4.local"

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
export SSH_USER="spilab"
export SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ---------------------------------------------------------------------------
# Crypto material paths (relative to $PROJECT_DIR)
# ---------------------------------------------------------------------------
export ORDERER_ORG_DIR="organizations/ordererOrganizations/${ORDERER_DOMAIN}"
export PEER_ORG1_DIR="organizations/peerOrganizations/${ORG1_DOMAIN}"
export PEER_ORG2_DIR="organizations/peerOrganizations/${ORG2_DOMAIN}"

# Orderer TLS
export ORDERER_CA="${PROJECT_DIR}/${ORDERER_ORG_DIR}/orderers/${ORDERER_HOST}/msp/tlscacerts/tlsca.${ORDERER_DOMAIN}-cert.pem"
export ORDERER_ADMIN_TLS_SIGN_CERT="${PROJECT_DIR}/${ORDERER_ORG_DIR}/orderers/${ORDERER_HOST}/tls/server.crt"
export ORDERER_ADMIN_TLS_PRIVATE_KEY="${PROJECT_DIR}/${ORDERER_ORG_DIR}/orderers/${ORDERER_HOST}/tls/server.key"

# Org1 peer TLS
export PEER0_ORG1_TLS_ROOTCERT="${PROJECT_DIR}/${PEER_ORG1_DIR}/peers/${PEER0_ORG1_HOST}/tls/ca.crt"

# Org2 peer TLS
export PEER0_ORG2_TLS_ROOTCERT="${PROJECT_DIR}/${PEER_ORG2_DIR}/peers/${PEER0_ORG2_HOST}/tls/ca.crt"

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------
export COMPOSE_DIR="$PROJECT_DIR/compose"

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------
export ORDERER_PORT=7050
export ORDERER_ADMIN_PORT=7053
export PEER0_ORG1_PORT=7051
export PEER0_ORG2_PORT=9051

# ---------------------------------------------------------------------------
# Colour helpers (safe for non-interactive use)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    export C_RED='\033[0;31m'
    export C_GREEN='\033[0;32m'
    export C_YELLOW='\033[1;33m'
    export C_BLUE='\033[0;34m'
    export C_BOLD='\033[1m'
    export C_RESET='\033[0m'
else
    export C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

log_info()  { echo -e "${C_GREEN}[INFO]${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
log_step()  { echo -e "\n${C_BOLD}${C_BLUE}>>> $*${C_RESET}"; }

# ---------------------------------------------------------------------------
# SSH helper — run a command on a remote Pi
# ---------------------------------------------------------------------------
# Usage: remote_exec <host> <command>
remote_exec() {
    local host="$1"; shift
    local cmd="$*"
    if command -v sshpass &>/dev/null; then
        sshpass -p "${SSH_PASS:-spilab}" ssh ${SSH_OPTS} "${SSH_USER}@${host}" "${cmd}"
    else
        ssh ${SSH_OPTS} "${SSH_USER}@${host}" "${cmd}"
    fi
}

# Usage: remote_copy <src> <host> <dest>
remote_copy() {
    local src="$1" host="$2" dest="$3"
    if command -v sshpass &>/dev/null; then
        sshpass -p "${SSH_PASS:-spilab}" scp ${SSH_OPTS} -r "${src}" "${SSH_USER}@${host}:${dest}"
    else
        scp ${SSH_OPTS} -r "${src}" "${SSH_USER}@${host}:${dest}"
    fi
}
