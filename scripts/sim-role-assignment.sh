#!/usr/bin/env bash
# =============================================================================
# sim-role-assignment.sh — Demonstrate service and blockchain role management
#
# Exercises Family 2 (Service Management) functions:
#   1. Assign blockchain roles to all 4 UAVs
#   2. Assign service roles with Docker images and positions
#   3. Assign target positions to deployed UAVs
#   4. Query all active role assignments
#   5. Revoke a service role
#   6. Re-query to show the change
#
# Usage: ./sim-role-assignment.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sim-env.sh"

header "UAV Role Assignment Simulation"
info "Channel   : ${CHANNEL_NAME}"
info "Chaincode : ${CC_NAME}"
echo ""

# -----------------------------------------------------------------------
# Step 1 — Assign blockchain roles
# -----------------------------------------------------------------------
header "Step 1: Assign Blockchain Roles"

declare -A BC_ROLES
BC_ROLES[UAV-001]="ORDERER"
BC_ROLES[UAV-002]="ENDORSER"
BC_ROLES[UAV-003]="ENDORSER"
BC_ROLES[UAV-004]="CLIENT"

for uav in UAV-001 UAV-002 UAV-003 UAV-004; do
  role=${BC_ROLES[$uav]}
  step "Assigning ${uav} -> blockchain role: ${role}"
  invoke_cc "{\"function\":\"AssignBlockchainRole\",\"Args\":[\"${uav}\",\"${role}\"]}" > /dev/null
done

ok "All blockchain roles assigned"
echo ""

# -----------------------------------------------------------------------
# Step 2 — Assign service roles with Docker images
# -----------------------------------------------------------------------
header "Step 2: Assign Service Roles"

# UAV-002 hosts the primary monitoring service.
step "Assigning UAV-002 as SERVICE_HOST (swarm-monitor:v1.2)..."
invoke_cc "{\"function\":\"AssignServiceRole\",\"Args\":[\"UAV-002\",\"SERVICE_HOST\",\"swarm-monitor:v1.2\",\"40.4170\",\"-3.7040\",\"60.0\"]}" > /dev/null

# UAV-003 hosts an analytics edge service.
step "Assigning UAV-003 as SERVICE_HOST (edge-analytics:v0.9)..."
invoke_cc "{\"function\":\"AssignServiceRole\",\"Args\":[\"UAV-003\",\"SERVICE_HOST\",\"edge-analytics:v0.9\",\"40.4172\",\"-3.7042\",\"55.0\"]}" > /dev/null

ok "Service roles assigned"
echo ""

# -----------------------------------------------------------------------
# Step 3 — Assign target positions
# -----------------------------------------------------------------------
header "Step 3: Assign Target Positions"

step "UAV-001 (orderer) -> patrol point Alpha (40.4180, -3.7050, 80m)"
invoke_cc "{\"function\":\"AssignTargetPosition\",\"Args\":[\"UAV-001\",\"40.4180\",\"-3.7050\",\"80.0\"]}" > /dev/null

step "UAV-002 (monitor) -> observation point Bravo (40.4190, -3.7060, 100m)"
invoke_cc "{\"function\":\"AssignTargetPosition\",\"Args\":[\"UAV-002\",\"40.4190\",\"-3.7060\",\"100.0\"]}" > /dev/null

step "UAV-003 (analytics) -> observation point Charlie (40.4200, -3.7070, 90m)"
invoke_cc "{\"function\":\"AssignTargetPosition\",\"Args\":[\"UAV-003\",\"40.4200\",\"-3.7070\",\"90.0\"]}" > /dev/null

ok "Target positions assigned"
echo ""

# -----------------------------------------------------------------------
# Step 4 — Query all active role assignments
# -----------------------------------------------------------------------
header "Step 4: Active Role Assignments"

step "Querying GetActiveRoleAssignments..."
roles_result=$(query_cc '{"function":"GetActiveRoleAssignments","Args":[]}')

if command -v jq &>/dev/null; then
  echo "$roles_result" | jq -r '
    ["Assignment ID","UAV","Type","Role","Active"],
    ["-------------","---","----","----","------"],
    (.[] | [.assignmentId, .uavId, .roleType, .roleName, (.active|tostring)])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$roles_result" | fmt_json
else
  echo "$roles_result"
fi
echo ""

# -----------------------------------------------------------------------
# Step 5 — Revoke a service role
# -----------------------------------------------------------------------
header "Step 5: Revoke Service Role from UAV-003"

step "Current UAV-003 state:"
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"UAV-003\"]}" | jq '{uavId, status, serviceRole, assignedImage}' 2>/dev/null || \
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"UAV-003\"]}"
echo ""

step "Revoking service role from UAV-003..."
invoke_cc "{\"function\":\"RevokeServiceRole\",\"Args\":[\"UAV-003\"]}" > /dev/null

step "UAV-003 state after revocation:"
query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"UAV-003\"]}" | jq '{uavId, status, serviceRole, assignedImage}' 2>/dev/null || \
  query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"UAV-003\"]}"
echo ""

# -----------------------------------------------------------------------
# Step 6 — Re-query active assignments (should show UAV-003's role revoked)
# -----------------------------------------------------------------------
header "Step 6: Active Role Assignments After Revocation"

step "Querying GetActiveRoleAssignments..."
roles_result=$(query_cc '{"function":"GetActiveRoleAssignments","Args":[]}')

if command -v jq &>/dev/null; then
  echo "$roles_result" | jq -r '
    ["Assignment ID","UAV","Type","Role","Active"],
    ["-------------","---","----","----","------"],
    (.[] | [.assignmentId, .uavId, .roleType, .roleName, (.active|tostring)])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$roles_result" | fmt_json
else
  echo "$roles_result"
fi
echo ""

# -----------------------------------------------------------------------
# Final DT state
# -----------------------------------------------------------------------
header "Final Digital Twin State"

all_uavs=$(query_cc '{"function":"GetAllUAVs","Args":[]}')
if command -v jq &>/dev/null; then
  echo "$all_uavs" | jq -r '
    ["UAV","Status","Blockchain","Service","Image","Lat","Lon","Alt"],
    ["---","------","----------","-------","-----","---","---","---"],
    (.[] | [.uavId, .status, .blockchainRole, .serviceRole, .assignedImage,
            (.position.latitude|tostring), (.position.longitude|tostring),
            (.position.altitude|tostring)])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$all_uavs" | fmt_json
else
  echo "$all_uavs"
fi
echo ""

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_tx_summary
ok "Role assignment simulation complete."
