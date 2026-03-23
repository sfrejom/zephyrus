#!/usr/bin/env bash
# =============================================================================
# sim-env.sh — Shared environment and helper functions for UAV swarm simulation
# Source this file at the top of every sim-*.sh / query-*.sh script.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# TLS certificate paths (inside CLI container or host with matching mounts)
# ---------------------------------------------------------------------------
# Base path where organizations/ is mounted inside CLI containers
_ORG_BASE="/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations"
export ORDERER_CA=${ORDERER_CA:-${_ORG_BASE}/ordererOrganizations/uav-network.local/orderers/orderer.uav-network.local/msp/tlscacerts/tlsca.uav-network.local-cert.pem}
export PEER0_ORG1_CA=${PEER0_ORG1_CA:-${_ORG_BASE}/peerOrganizations/org1.uav-network.local/peers/peer0.org1.uav-network.local/tls/ca.crt}
export PEER0_ORG2_CA=${PEER0_ORG2_CA:-${_ORG_BASE}/peerOrganizations/org2.uav-network.local/peers/peer0.org2.uav-network.local/tls/ca.crt}

export CHANNEL_NAME=${CHANNEL_NAME:-swarm-management}
export CC_NAME=${CC_NAME:-swarm-management}
export ORDERER_ADDR=${ORDERER_ADDR:-orderer.uav-network.local:7050}
export PEER0_ORG1_ADDR=${PEER0_ORG1_ADDR:-peer0.org1.uav-network.local:7051}
export PEER0_ORG2_ADDR=${PEER0_ORG2_ADDR:-peer0.org2.uav-network.local:9051}

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
header()  { echo -e "\n${BOLD}=== $* ===${NC}"; }
step()    { echo -e "${CYAN}--->${NC} $*"; }

# ---------------------------------------------------------------------------
# Timing helpers — nanosecond precision where available
# ---------------------------------------------------------------------------
# Returns current time in milliseconds.
now_ms() {
  if date +%s%N >/dev/null 2>&1; then
    echo $(( $(date +%s%N) / 1000000 ))
  else
    # Fallback for environments without %N (e.g. BusyBox date).
    echo $(( $(date +%s) * 1000 ))
  fi
}

# Print elapsed time given a start timestamp (ms).
elapsed_ms() {
  local start=$1
  local end
  end=$(now_ms)
  echo $(( end - start ))
}

# ---------------------------------------------------------------------------
# Transaction counters / latency tracking
# ---------------------------------------------------------------------------
TX_COUNT=0
TX_TOTAL_MS=0
TX_FAILURES=0

record_tx() {
  local ms=$1
  TX_COUNT=$(( TX_COUNT + 1 ))
  TX_TOTAL_MS=$(( TX_TOTAL_MS + ms ))
}

record_failure() {
  TX_FAILURES=$(( TX_FAILURES + 1 ))
}

print_tx_summary() {
  header "Transaction Summary"
  echo -e "  Total transactions : ${BOLD}${TX_COUNT}${NC}"
  echo -e "  Failed             : ${BOLD}${TX_FAILURES}${NC}"
  if [ "$TX_COUNT" -gt 0 ]; then
    local avg=$(( TX_TOTAL_MS / TX_COUNT ))
    echo -e "  Total latency      : ${BOLD}${TX_TOTAL_MS} ms${NC}"
    echo -e "  Average latency    : ${BOLD}${avg} ms${NC}"
  fi
}

# ---------------------------------------------------------------------------
# Chaincode invocation helpers
# ---------------------------------------------------------------------------

# invoke_cc — submit a transaction (requires endorsement from both orgs).
# Arg 1: JSON function call string, e.g. '{"function":"Foo","Args":["a","b"]}'
# Returns the peer output on stdout; sets $INVOKE_RC to the exit code.
INVOKE_RC=0
invoke_cc() {
  local func_json="$1"
  local start
  start=$(now_ms)

  local output
  set +e
  output=$(peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "${func_json}" \
    --waitForEvent 2>&1)
  INVOKE_RC=$?
  set -e

  local ms
  ms=$(elapsed_ms "$start")

  if [ $INVOKE_RC -eq 0 ]; then
    record_tx "$ms"
    ok "invoke (${ms} ms): ${func_json}"
  else
    record_failure
    fail "invoke (${ms} ms, rc=${INVOKE_RC}): ${func_json}"
  fi

  echo "$output"
}

# invoke_cc_quiet — same as invoke_cc but suppresses the per-tx log line.
invoke_cc_quiet() {
  local func_json="$1"
  local start
  start=$(now_ms)

  local output
  set +e
  output=$(peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "${func_json}" \
    --waitForEvent 2>&1)
  INVOKE_RC=$?
  set -e

  local ms
  ms=$(elapsed_ms "$start")

  if [ $INVOKE_RC -eq 0 ]; then
    record_tx "$ms"
  else
    record_failure
  fi

  echo "$output"
}

# query_cc — evaluate a read-only query (single peer, no orderer needed).
# Arg 1: JSON function call string.
QUERY_RC=0
query_cc() {
  local func_json="$1"
  local output
  set +e
  output=$(peer chaincode query \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    -c "${func_json}" 2>&1)
  QUERY_RC=$?
  set -e
  echo "$output"
}

# ---------------------------------------------------------------------------
# JSON formatting (uses jq if available, cat otherwise)
# ---------------------------------------------------------------------------
fmt_json() {
  if command -v jq &>/dev/null; then
    jq '.'
  else
    cat
  fi
}

# ---------------------------------------------------------------------------
# Random number helper (bash-native, no external deps)
# ---------------------------------------------------------------------------
# rand_range MIN MAX — prints a random integer in [MIN, MAX].
rand_range() {
  local min=$1 max=$2
  echo $(( RANDOM % (max - min + 1) + min ))
}

# rand_float MIN MAX DECIMALS — prints a random float, e.g. rand_float 10 90 1
rand_float() {
  local min=$1 max=$2 dec=${3:-1}
  local int_part frac_part
  int_part=$(rand_range "$min" "$max")
  frac_part=$(rand_range 0 9)
  echo "${int_part}.${frac_part}"
}
