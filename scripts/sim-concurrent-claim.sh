#!/usr/bin/env bash
# =============================================================================
# sim-concurrent-claim.sh — Demonstrate MVCC conflict resolution
#
# This script demonstrates the key advantage of blockchain consensus for
# role management as described in the research paper:
#
#   "If two UAVs try to claim the same role, only the first committed
#    transaction succeeds — Fabric's MVCC mechanism detects the read-set
#    version conflict and invalidates the second transaction."
#
# We simulate this by:
#   1. Ensuring two UAVs are in STANDBY (eligible for role assignment).
#   2. Firing two rapid, back-to-back AssignServiceRole invocations that
#      both attempt to assign SERVICE_HOST for the same target position.
#   3. At most one transaction should commit successfully; the other should
#      fail with an MVCC_READ_CONFLICT (or succeed if ordering serialises
#      them — either outcome is valid and demonstrates consensus at work).
#
# NOTE: On a real multi-peer Fabric network the conflict is most visible
# when both transactions land in the same block. On a single-orderer test
# network they may be serialised, in which case both succeed — the script
# reports the outcome either way.
#
# Usage: ./sim-concurrent-claim.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sim-env.sh"

header "MVCC Concurrent Claim Demonstration"
info "This test exercises Fabric's MVCC conflict detection."
info "Two UAVs will attempt to claim the same service role simultaneously."
echo ""

# -----------------------------------------------------------------------
# Setup — Register two fresh STANDBY UAVs for a clean test
# -----------------------------------------------------------------------
header "Setup: Register Two STANDBY UAVs"

UAV_A="UAV-ALPHA"
UAV_B="UAV-BRAVO"

step "Registering ${UAV_A} (SwarmOrg1MSP, CLIENT)..."
result_a=$(invoke_cc "{\"function\":\"RegisterUAV\",\"Args\":[\"${UAV_A}\",\"SwarmOrg1MSP\",\"CLIENT\"]}")
if [ $INVOKE_RC -ne 0 ]; then
  # May already exist from a previous run — check and continue.
  if echo "$result_a" | grep -q "already exists"; then
    warn "${UAV_A} already registered, continuing..."
  else
    fail "Could not register ${UAV_A}: $result_a"
  fi
fi

step "Registering ${UAV_B} (SwarmOrg2MSP, CLIENT)..."
result_b=$(invoke_cc "{\"function\":\"RegisterUAV\",\"Args\":[\"${UAV_B}\",\"SwarmOrg2MSP\",\"CLIENT\"]}")
if [ $INVOKE_RC -ne 0 ]; then
  if echo "$result_b" | grep -q "already exists"; then
    warn "${UAV_B} already registered, continuing..."
  else
    fail "Could not register ${UAV_B}: $result_b"
  fi
fi

# Show initial state.
step "Initial state:"
for uav in "$UAV_A" "$UAV_B"; do
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${uav}\"]}" | \
    jq '{uavId, status, serviceRole}' 2>/dev/null || \
    query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${uav}\"]}"
done
echo ""

# -----------------------------------------------------------------------
# Concurrent invocations
# -----------------------------------------------------------------------
header "Concurrent Role Claim"

TARGET_IMAGE="surveillance-cam:v3.0"
TARGET_LAT="40.4200"
TARGET_LON="-3.7100"
TARGET_ALT="75.0"

info "Both ${UAV_A} and ${UAV_B} will attempt to become SERVICE_HOST"
info "at the same target position (${TARGET_LAT}, ${TARGET_LON}, ${TARGET_ALT}m)"
echo ""

# Fire both invocations in background subshells so they hit the orderer
# as close together as possible.
RESULT_FILE_A=$(mktemp)
RESULT_FILE_B=$(mktemp)
RC_FILE_A=$(mktemp)
RC_FILE_B=$(mktemp)

step "Launching concurrent AssignServiceRole invocations..."

(
  output=$(peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "{\"function\":\"AssignServiceRole\",\"Args\":[\"${UAV_A}\",\"SERVICE_HOST\",\"${TARGET_IMAGE}\",\"${TARGET_LAT}\",\"${TARGET_LON}\",\"${TARGET_ALT}\"]}" \
    --waitForEvent 2>&1)
  echo $? > "$RC_FILE_A"
  echo "$output" > "$RESULT_FILE_A"
) &
PID_A=$!

(
  output=$(peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "{\"function\":\"AssignServiceRole\",\"Args\":[\"${UAV_B}\",\"SERVICE_HOST\",\"${TARGET_IMAGE}\",\"${TARGET_LAT}\",\"${TARGET_LON}\",\"${TARGET_ALT}\"]}" \
    --waitForEvent 2>&1)
  echo $? > "$RC_FILE_B"
  echo "$output" > "$RESULT_FILE_B"
) &
PID_B=$!

# Wait for both to finish.
wait $PID_A 2>/dev/null
wait $PID_B 2>/dev/null

RC_A=$(cat "$RC_FILE_A")
RC_B=$(cat "$RC_FILE_B")
OUTPUT_A=$(cat "$RESULT_FILE_A")
OUTPUT_B=$(cat "$RESULT_FILE_B")

rm -f "$RESULT_FILE_A" "$RESULT_FILE_B" "$RC_FILE_A" "$RC_FILE_B"

# -----------------------------------------------------------------------
# Analyse results
# -----------------------------------------------------------------------
header "Results"

echo -e "${BOLD}${UAV_A} invocation:${NC}"
if [ "$RC_A" = "0" ]; then
  ok "Transaction COMMITTED successfully"
else
  fail "Transaction FAILED (rc=${RC_A})"
fi
if echo "$OUTPUT_A" | grep -qi "MVCC_READ_CONFLICT"; then
  warn "MVCC_READ_CONFLICT detected — this is EXPECTED for the losing transaction"
fi
echo "  Output: $(echo "$OUTPUT_A" | tail -3)"
echo ""

echo -e "${BOLD}${UAV_B} invocation:${NC}"
if [ "$RC_B" = "0" ]; then
  ok "Transaction COMMITTED successfully"
else
  fail "Transaction FAILED (rc=${RC_B})"
fi
if echo "$OUTPUT_B" | grep -qi "MVCC_READ_CONFLICT"; then
  warn "MVCC_READ_CONFLICT detected — this is EXPECTED for the losing transaction"
fi
echo "  Output: $(echo "$OUTPUT_B" | tail -3)"
echo ""

# -----------------------------------------------------------------------
# Interpret the outcome
# -----------------------------------------------------------------------
header "Interpretation"

BOTH_OK=false
if [ "$RC_A" = "0" ] && [ "$RC_B" = "0" ]; then
  BOTH_OK=true
fi

if $BOTH_OK; then
  info "Both transactions committed. This can happen when:"
  info "  - The orderer serialised them into different blocks, or"
  info "  - They touched different state keys (different UAV IDs)"
  info "In either case, Fabric consensus ensured deterministic ordering."
  info ""
  info "Since the two UAVs are different entities (${UAV_A} vs ${UAV_B}),"
  info "there is no MVCC conflict on the primary key. A conflict occurs"
  info "only when two transactions read and write the SAME key in one block."
else
  info "One transaction was invalidated — Fabric's MVCC validation detected"
  info "a read-set version conflict. This is the blockchain's guarantee that"
  info "concurrent role claims are resolved deterministically."
fi
echo ""

# Show final state of both UAVs.
header "Final UAV States"

for uav in "$UAV_A" "$UAV_B"; do
  step "${uav}:"
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${uav}\"]}" | \
    jq '{uavId, status, serviceRole, assignedImage}' 2>/dev/null || \
    query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${uav}\"]}"
  echo ""
done

# -----------------------------------------------------------------------
# Bonus — demonstrate same-key conflict with a position update race
# -----------------------------------------------------------------------
header "Bonus: Same-Key Write Conflict"

info "Now both UAVs will try to update the SAME UAV's position (${UAV_A})."
info "This is where MVCC_READ_CONFLICT is most likely."
echo ""

RESULT_FILE_A=$(mktemp)
RESULT_FILE_B=$(mktemp)
RC_FILE_A=$(mktemp)
RC_FILE_B=$(mktemp)

step "Launching two concurrent AssignTargetPosition on ${UAV_A}..."

(
  output=$(peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "{\"function\":\"AssignTargetPosition\",\"Args\":[\"${UAV_A}\",\"41.0000\",\"-4.0000\",\"100.0\"]}" \
    --waitForEvent 2>&1)
  echo $? > "$RC_FILE_A"
  echo "$output" > "$RESULT_FILE_A"
) &
PID_A=$!

(
  output=$(peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "{\"function\":\"AssignTargetPosition\",\"Args\":[\"${UAV_A}\",\"42.0000\",\"-5.0000\",\"200.0\"]}" \
    --waitForEvent 2>&1)
  echo $? > "$RC_FILE_B"
  echo "$output" > "$RESULT_FILE_B"
) &
PID_B=$!

wait $PID_A 2>/dev/null
wait $PID_B 2>/dev/null

RC_A=$(cat "$RC_FILE_A")
RC_B=$(cat "$RC_FILE_B")
OUTPUT_A=$(cat "$RESULT_FILE_A")
OUTPUT_B=$(cat "$RESULT_FILE_B")

rm -f "$RESULT_FILE_A" "$RESULT_FILE_B" "$RC_FILE_A" "$RC_FILE_B"

echo -e "${BOLD}Position update #1 (41.0, -4.0, 100m):${NC}"
if [ "$RC_A" = "0" ]; then ok "COMMITTED"; else fail "FAILED (rc=${RC_A})"; fi
if echo "$OUTPUT_A" | grep -qi "MVCC_READ_CONFLICT"; then
  warn "MVCC_READ_CONFLICT — expected for the losing write"
fi

echo -e "${BOLD}Position update #2 (42.0, -5.0, 200m):${NC}"
if [ "$RC_B" = "0" ]; then ok "COMMITTED"; else fail "FAILED (rc=${RC_B})"; fi
if echo "$OUTPUT_B" | grep -qi "MVCC_READ_CONFLICT"; then
  warn "MVCC_READ_CONFLICT — expected for the losing write"
fi
echo ""

step "Final position of ${UAV_A}:"
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${UAV_A}\"]}" | \
  jq '{uavId, position}' 2>/dev/null || \
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${UAV_A}\"]}"
echo ""

info "Whichever position is stored is the one whose transaction was ordered"
info "first by the Raft orderer — deterministic and auditable."
echo ""

ok "MVCC conflict demonstration complete."
