#!/usr/bin/env bash
# =============================================================================
# sim-handover-flow.sh — Simulate a complete UAV handover process
#
# Follows the multi-phase handover protocol from the research paper:
#   1. Deplete a UAV's battery via telemetry update
#   2. Detect depletion (CheckDepletionThreshold)
#   3. Initiate handover
#   4. Select a STANDBY replacement
#   5. Start service migration
#   6. Complete migration — role transfer
#   7. Verify final state (depleted → OFFLINE, replacement → ACTIVE)
#
# By default depletes UAV-002 and replaces it with UAV-004.
#
# Usage: ./sim-handover-flow.sh [depleted_uav] [replacement_uav]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sim-env.sh"

DEPLETED_UAV=${1:-UAV-002}
REPLACEMENT_UAV=${2:-UAV-004}
BATTERY_THRESHOLD=20

header "UAV Handover Simulation"
info "Depleted UAV    : ${DEPLETED_UAV}"
info "Replacement UAV : ${REPLACEMENT_UAV}"
info "Battery threshold: ${BATTERY_THRESHOLD}%"
echo ""

# -----------------------------------------------------------------------
# Phase 0 — Show initial state of both UAVs
# -----------------------------------------------------------------------
header "Phase 0: Initial State"

step "Querying ${DEPLETED_UAV}..."
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${DEPLETED_UAV}\"]}" | fmt_json
echo ""

step "Querying ${REPLACEMENT_UAV}..."
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${REPLACEMENT_UAV}\"]}" | fmt_json
echo ""

# -----------------------------------------------------------------------
# Phase 1 — Deplete the UAV by sending low-battery telemetry
# -----------------------------------------------------------------------
header "Phase 1: Deplete ${DEPLETED_UAV} battery"

step "Sending telemetry with battery at 12%..."
invoke_cc "{\"function\":\"UpdateTelemetry\",\"Args\":[\"${DEPLETED_UAV}\",\"12.0\",\"78.5\",\"65.0\",\"40.0\",\"72.0\",\"40.4170\",\"-3.7040\",\"45.0\"]}" > /dev/null

step "Verifying telemetry update..."
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${DEPLETED_UAV}\"]}" | fmt_json
echo ""

# -----------------------------------------------------------------------
# Phase 2 — Detect depletion threshold
# -----------------------------------------------------------------------
header "Phase 2: Detect Depletion"

step "Calling CheckDepletionThreshold(${DEPLETED_UAV}, ${BATTERY_THRESHOLD})..."
result=$(invoke_cc "{\"function\":\"CheckDepletionThreshold\",\"Args\":[\"${DEPLETED_UAV}\",\"${BATTERY_THRESHOLD}\"]}")
echo "$result"

# Verify the UAV is now DEPLETED.
step "Verifying ${DEPLETED_UAV} status is DEPLETED..."
state=$(query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${DEPLETED_UAV}\"]}")
echo "$state" | fmt_json

status=$(echo "$state" | jq -r '.status' 2>/dev/null || echo "UNKNOWN")
if [ "$status" = "DEPLETED" ]; then
  ok "${DEPLETED_UAV} is now DEPLETED — depletion event emitted"
else
  fail "${DEPLETED_UAV} status is '${status}', expected DEPLETED"
  warn "Handover cannot proceed without DEPLETED status. Aborting."
  exit 1
fi
echo ""

# -----------------------------------------------------------------------
# Phase 3 — Initiate handover
# -----------------------------------------------------------------------
header "Phase 3: Initiate Handover"

step "Calling InitiateHandover(${DEPLETED_UAV})..."
result=$(invoke_cc "{\"function\":\"InitiateHandover\",\"Args\":[\"${DEPLETED_UAV}\"]}")
echo "$result"

# Extract handover ID from the invoke result.
# The chaincode returns the handover ID as the transaction response payload.
# In practice this appears in the peer output; we also query active handovers.
step "Querying active handovers to find our handover ID..."
handovers=$(query_cc '{"function":"GetActiveHandovers","Args":[]}')
echo "$handovers" | fmt_json

# Extract the handover ID for this depleted UAV.
HANDOVER_ID=$(echo "$handovers" | jq -r ".[] | select(.depletedUav==\"${DEPLETED_UAV}\") | .handoverId" 2>/dev/null | head -1)

if [ -z "$HANDOVER_ID" ] || [ "$HANDOVER_ID" = "null" ]; then
  fail "Could not determine handover ID. Trying to extract from invoke output..."
  # Fallback: try to parse from the invoke result (payload is printed by peer CLI).
  HANDOVER_ID=$(echo "$result" | grep -o 'handover-[A-Za-z0-9_-]*' | head -1)
fi

if [ -z "$HANDOVER_ID" ]; then
  fail "Unable to find handover ID. Aborting."
  exit 1
fi

ok "Handover ID: ${HANDOVER_ID}"
echo ""

# -----------------------------------------------------------------------
# Phase 4 — Select replacement
# -----------------------------------------------------------------------
header "Phase 4: Select Replacement"

step "Verifying ${REPLACEMENT_UAV} is STANDBY..."
rep_state=$(query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${REPLACEMENT_UAV}\"]}")
rep_status=$(echo "$rep_state" | jq -r '.status' 2>/dev/null || echo "UNKNOWN")

if [ "$rep_status" != "STANDBY" ]; then
  warn "${REPLACEMENT_UAV} status is '${rep_status}' (expected STANDBY)"
  warn "Proceeding anyway — chaincode will enforce the constraint"
fi

step "Calling SelectReplacement(${HANDOVER_ID}, ${REPLACEMENT_UAV})..."
invoke_cc "{\"function\":\"SelectReplacement\",\"Args\":[\"${HANDOVER_ID}\",\"${REPLACEMENT_UAV}\"]}" > /dev/null

step "Verifying handover phase..."
query_cc "{\"function\":\"GetHandoverRecord\",\"Args\":[\"${HANDOVER_ID}\"]}" | fmt_json
echo ""

# -----------------------------------------------------------------------
# Phase 5 — Start migration
# -----------------------------------------------------------------------
header "Phase 5: Start Service Migration"

step "Calling StartMigration(${HANDOVER_ID})..."
invoke_cc "{\"function\":\"StartMigration\",\"Args\":[\"${HANDOVER_ID}\"]}" > /dev/null

step "Both UAVs should now be in REPLACING status..."
echo -e "  ${DEPLETED_UAV}:"
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${DEPLETED_UAV}\"]}" | jq '{status, serviceRole, assignedImage}' 2>/dev/null || \
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${DEPLETED_UAV}\"]}"

echo -e "  ${REPLACEMENT_UAV}:"
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${REPLACEMENT_UAV}\"]}" | jq '{status, serviceRole, assignedImage}' 2>/dev/null || \
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${REPLACEMENT_UAV}\"]}"
echo ""

# Simulate actual migration time (container image transfer in the real system).
info "Simulating migration delay (3 seconds)..."
sleep 3

# -----------------------------------------------------------------------
# Phase 6 — Complete migration
# -----------------------------------------------------------------------
header "Phase 6: Complete Migration"

step "Calling CompleteMigration(${HANDOVER_ID})..."
invoke_cc "{\"function\":\"CompleteMigration\",\"Args\":[\"${HANDOVER_ID}\"]}" > /dev/null
echo ""

# -----------------------------------------------------------------------
# Phase 7 — Verify final state
# -----------------------------------------------------------------------
header "Phase 7: Final State Verification"

step "${DEPLETED_UAV} (should be OFFLINE, no service role):"
dep_final=$(query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${DEPLETED_UAV}\"]}")
echo "$dep_final" | fmt_json

dep_status=$(echo "$dep_final" | jq -r '.status' 2>/dev/null || echo "")
dep_role=$(echo "$dep_final" | jq -r '.serviceRole' 2>/dev/null || echo "")
if [ "$dep_status" = "OFFLINE" ] && [ "$dep_role" = "NONE" ]; then
  ok "${DEPLETED_UAV}: OFFLINE, service role cleared"
else
  fail "${DEPLETED_UAV}: unexpected state (status=${dep_status}, role=${dep_role})"
fi
echo ""

step "${REPLACEMENT_UAV} (should be ACTIVE with SERVICE_HOST):"
rep_final=$(query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${REPLACEMENT_UAV}\"]}")
echo "$rep_final" | fmt_json

rep_status=$(echo "$rep_final" | jq -r '.status' 2>/dev/null || echo "")
rep_role=$(echo "$rep_final" | jq -r '.serviceRole' 2>/dev/null || echo "")
if [ "$rep_status" = "ACTIVE" ] && [ "$rep_role" = "SERVICE_HOST" ]; then
  ok "${REPLACEMENT_UAV}: ACTIVE, inherited SERVICE_HOST role"
else
  fail "${REPLACEMENT_UAV}: unexpected state (status=${rep_status}, role=${rep_role})"
fi
echo ""

# -----------------------------------------------------------------------
# Audit trail
# -----------------------------------------------------------------------
header "Handover Audit Trail"

step "Handover record:"
query_cc "{\"function\":\"GetHandoverRecord\",\"Args\":[\"${HANDOVER_ID}\"]}" | fmt_json
echo ""

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_tx_summary
ok "Handover simulation complete."
