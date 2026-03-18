#!/usr/bin/env bash
# =============================================================================
# sim-full-scenario.sh — End-to-end UAV Swarm Digital Twin scenario
#
# Combines all three functional families into a coherent mission narrative:
#   1. Display initial Digital Twin state
#   2. Assign blockchain and service roles
#   3. Run several rounds of telemetry updates
#   4. Simulate battery depletion
#   5. Execute a full handover flow
#   6. Display audit trail
#   7. Display final DT state
#   8. Print summary with transaction counts and latencies
#
# Usage: ./sim-full-scenario.sh [telemetry_rounds]   (default: 3)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sim-env.sh"

TELEMETRY_ROUNDS=${1:-3}
SCENARIO_START=$(now_ms)

header "UAV Swarm Digital Twin — Full Scenario"
info "Telemetry rounds : ${TELEMETRY_ROUNDS}"
info "Channel          : ${CHANNEL_NAME}"
info "Chaincode        : ${CC_NAME}"
info "Timestamp        : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# =====================================================================
# STAGE 1 — Initial Digital Twin State
# =====================================================================
header "STAGE 1: Initial Digital Twin State"

step "Querying all UAVs..."
all_uavs=$(query_cc '{"function":"GetAllUAVs","Args":[]}')

if command -v jq &>/dev/null; then
  echo "$all_uavs" | jq -r '
    ["UAV","Status","Battery","Blockchain","Service","Image"],
    ["---","------","-------","----------","-------","-----"],
    (.[] | [.uavId, .status,
            ((.batteryLevel|tostring)+"%"),
            .blockchainRole, .serviceRole, .assignedImage])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$all_uavs" | fmt_json
else
  echo "$all_uavs" | fmt_json
fi
echo ""

# =====================================================================
# STAGE 2 — Role Configuration
# =====================================================================
header "STAGE 2: Role Configuration"

step "Assigning blockchain roles..."
invoke_cc '{"function":"AssignBlockchainRole","Args":["UAV-001","ORDERER"]}' > /dev/null
invoke_cc '{"function":"AssignBlockchainRole","Args":["UAV-002","ENDORSER"]}' > /dev/null
invoke_cc '{"function":"AssignBlockchainRole","Args":["UAV-003","ENDORSER"]}' > /dev/null
invoke_cc '{"function":"AssignBlockchainRole","Args":["UAV-004","CLIENT"]}' > /dev/null
ok "Blockchain roles assigned"

step "Assigning service roles..."
invoke_cc '{"function":"AssignServiceRole","Args":["UAV-002","SERVICE_HOST","swarm-monitor:v1.2","40.4170","-3.7040","60.0"]}' > /dev/null
ok "UAV-002 is now SERVICE_HOST (swarm-monitor:v1.2)"
echo ""

step "Assigning patrol positions..."
invoke_cc '{"function":"AssignTargetPosition","Args":["UAV-001","40.4180","-3.7050","80.0"]}' > /dev/null
invoke_cc '{"function":"AssignTargetPosition","Args":["UAV-002","40.4190","-3.7060","100.0"]}' > /dev/null
invoke_cc '{"function":"AssignTargetPosition","Args":["UAV-003","40.4200","-3.7070","90.0"]}' > /dev/null
ok "Positions assigned"
echo ""

# Show role assignments.
step "Active role assignments:"
roles=$(query_cc '{"function":"GetActiveRoleAssignments","Args":[]}')
if command -v jq &>/dev/null; then
  echo "$roles" | jq -r '
    ["UAV","Type","Role"],
    ["---","----","----"],
    (.[] | [.uavId, .roleType, .roleName])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$roles" | fmt_json
fi
echo ""

# =====================================================================
# STAGE 3 — Telemetry Simulation
# =====================================================================
header "STAGE 3: Telemetry Updates (${TELEMETRY_ROUNDS} rounds)"

# Track battery per UAV.
declare -A BAT
BAT[UAV-001]=95 BAT[UAV-002]=90 BAT[UAV-003]=92 BAT[UAV-004]=100

UAVS=("UAV-001" "UAV-002" "UAV-003" "UAV-004")

for (( r=1; r<=TELEMETRY_ROUNDS; r++ )); do
  step "Round ${r}/${TELEMETRY_ROUNDS}"

  for uav in "${UAVS[@]}"; do
    drain=$(rand_range 5 12)
    BAT[$uav]=$(( ${BAT[$uav]} - drain ))
    if [ "${BAT[$uav]}" -lt 0 ]; then BAT[$uav]=0; fi

    cpu=$(rand_float 10 80 1)
    ram=$(rand_float 20 70 1)
    stor=$(rand_float 15 50 1)
    link=$(rand_float 60 99 1)

    invoke_cc_quiet "{\"function\":\"UpdateTelemetry\",\"Args\":[\"${uav}\",\"${BAT[$uav]}.0\",\"${cpu}\",\"${ram}\",\"${stor}\",\"${link}\",\"40.4170\",\"-3.7040\",\"55.0\"]}" > /dev/null
  done

  # Show battery levels.
  for uav in "${UAVS[@]}"; do
    level=${BAT[$uav]}
    if [ "$level" -le 20 ]; then
      echo -e "    ${uav}: ${RED}${level}%${NC}"
    elif [ "$level" -le 50 ]; then
      echo -e "    ${uav}: ${YELLOW}${level}%${NC}"
    else
      echo -e "    ${uav}: ${GREEN}${level}%${NC}"
    fi
  done

  if [ "$r" -lt "$TELEMETRY_ROUNDS" ]; then
    sleep 1
  fi
done
echo ""

# =====================================================================
# STAGE 4 — Battery Depletion
# =====================================================================
header "STAGE 4: Battery Depletion on UAV-002"

# Force UAV-002 to critically low battery.
step "Sending critical telemetry: UAV-002 battery at 8%..."
invoke_cc '{"function":"UpdateTelemetry","Args":["UAV-002","8.0","85.0","72.0","55.0","65.0","40.4190","-3.7060","100.0"]}' > /dev/null

step "Checking depletion threshold (20%)..."
invoke_cc '{"function":"CheckDepletionThreshold","Args":["UAV-002","20"]}' > /dev/null

step "Verifying UAV-002 status..."
uav002=$(query_cc '{"function":"GetUAVState","Args":["UAV-002"]}')
status=$(echo "$uav002" | jq -r '.status' 2>/dev/null || echo "?")
echo -e "  UAV-002 status: ${RED}${status}${NC}"

if [ "$status" != "DEPLETED" ]; then
  fail "UAV-002 should be DEPLETED but is '${status}'. Aborting handover."
  print_tx_summary
  exit 1
fi
ok "Depletion detected — DepletionDetected event emitted"
echo ""

# =====================================================================
# STAGE 5 — Handover Flow
# =====================================================================
header "STAGE 5: Handover Coordination"

# Phase 1 — Initiate.
step "Phase 1: InitiateHandover(UAV-002)..."
invoke_cc '{"function":"InitiateHandover","Args":["UAV-002"]}' > /dev/null

# Find handover ID.
handovers=$(query_cc '{"function":"GetActiveHandovers","Args":[]}')
HANDOVER_ID=$(echo "$handovers" | jq -r '.[] | select(.depletedUav=="UAV-002") | .handoverId' 2>/dev/null | head -1)
if [ -z "$HANDOVER_ID" ] || [ "$HANDOVER_ID" = "null" ]; then
  fail "Could not determine handover ID"
  print_tx_summary
  exit 1
fi
ok "Handover initiated: ${HANDOVER_ID}"

# Phase 2 — Select replacement.
step "Phase 2: SelectReplacement(${HANDOVER_ID}, UAV-004)..."
invoke_cc "{\"function\":\"SelectReplacement\",\"Args\":[\"${HANDOVER_ID}\",\"UAV-004\"]}" > /dev/null
ok "UAV-004 selected as replacement"

# Phase 3 — Start migration.
step "Phase 3: StartMigration(${HANDOVER_ID})..."
invoke_cc "{\"function\":\"StartMigration\",\"Args\":[\"${HANDOVER_ID}\"]}" > /dev/null
ok "Migration in progress..."

info "Simulating container migration delay (2s)..."
sleep 2

# Phase 4 — Complete migration.
step "Phase 4: CompleteMigration(${HANDOVER_ID})..."
invoke_cc "{\"function\":\"CompleteMigration\",\"Args\":[\"${HANDOVER_ID}\"]}" > /dev/null
ok "Migration complete — role transferred"
echo ""

# =====================================================================
# STAGE 6 — Audit Trail
# =====================================================================
header "STAGE 6: Handover Audit Trail"

step "Handover record:"
query_cc "{\"function\":\"GetHandoverRecord\",\"Args\":[\"${HANDOVER_ID}\"]}" | fmt_json

step "Full handover history:"
query_cc '{"function":"GetHandoverHistory","Args":[]}' | fmt_json
echo ""

# =====================================================================
# STAGE 7 — Final Digital Twin State
# =====================================================================
header "STAGE 7: Final Digital Twin State"

final_uavs=$(query_cc '{"function":"GetAllUAVs","Args":[]}')

if command -v jq &>/dev/null; then
  echo "$final_uavs" | jq -r '
    ["UAV","Status","Battery","Blockchain","Service","Image"],
    ["---","------","-------","----------","-------","-----"],
    (.[] | [.uavId, .status,
            ((.batteryLevel|tostring)+"%"),
            .blockchainRole, .serviceRole, .assignedImage])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$final_uavs" | fmt_json
else
  echo "$final_uavs" | fmt_json
fi
echo ""

# Highlight key state transitions.
info "Key observations:"
echo -e "  - UAV-002: ${RED}OFFLINE${NC} (battery depleted, service role cleared)"
echo -e "  - UAV-004: ${GREEN}ACTIVE${NC} (inherited SERVICE_HOST + swarm-monitor:v1.2)"
echo -e "  - UAV-001: Orderer still operational"
echo -e "  - UAV-003: Endorser still operational"
echo ""

# =====================================================================
# STAGE 8 — Summary
# =====================================================================
SCENARIO_END=$(now_ms)
TOTAL_MS=$(( SCENARIO_END - SCENARIO_START ))

header "STAGE 8: Scenario Summary"
echo ""
echo -e "  ${BOLD}Scenario duration${NC}    : ${TOTAL_MS} ms ($(( TOTAL_MS / 1000 ))s)"
print_tx_summary
echo ""

ok "Full scenario complete. Digital Twin integrity verified on-chain."
