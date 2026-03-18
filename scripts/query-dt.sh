#!/usr/bin/env bash
# =============================================================================
# query-dt.sh — Query and display the current Digital Twin state
#
# Reads the full DT from the ledger and presents:
#   1. All UAV descriptors (formatted table)
#   2. Active handovers (if any)
#   3. Active role assignments
#   4. UAVs grouped by status
#
# Usage: ./query-dt.sh                     (full report)
#        ./query-dt.sh uav <uav-id>        (single UAV)
#        ./query-dt.sh status <status>      (UAVs by status)
#        ./query-dt.sh handover <id>        (single handover)
#        ./query-dt.sh handovers            (all active handovers)
#        ./query-dt.sh history              (full handover history)
#        ./query-dt.sh roles                (active role assignments)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sim-env.sh"

MODE=${1:-full}
ARG=${2:-}

# ---------------------------------------------------------------------------
# Sub-command: single UAV
# ---------------------------------------------------------------------------
if [ "$MODE" = "uav" ]; then
  if [ -z "$ARG" ]; then
    fail "Usage: $0 uav <uav-id>"
    exit 1
  fi
  header "UAV Descriptor: ${ARG}"
  result=$(query_cc "{\"function\":\"GetUAVState\",\"Args\":[\"${ARG}\"]}")
  if [ $QUERY_RC -ne 0 ]; then
    fail "$result"
    exit 1
  fi
  echo "$result" | fmt_json
  exit 0
fi

# ---------------------------------------------------------------------------
# Sub-command: UAVs by status
# ---------------------------------------------------------------------------
if [ "$MODE" = "status" ]; then
  if [ -z "$ARG" ]; then
    fail "Usage: $0 status <ACTIVE|DEPLETED|STANDBY|REPLACING|OFFLINE>"
    exit 1
  fi
  header "UAVs with status: ${ARG}"
  result=$(query_cc "{\"function\":\"GetUAVsByStatus\",\"Args\":[\"${ARG}\"]}")
  if command -v jq &>/dev/null; then
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "?")
    info "Found ${count} UAV(s)"
    echo "$result" | jq -r '
      .[] | "  \(.uavId)  bat=\(.batteryLevel)%  role=\(.blockchainRole)  svc=\(.serviceRole)"
    ' 2>/dev/null || echo "$result" | fmt_json
  else
    echo "$result" | fmt_json
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Sub-command: single handover
# ---------------------------------------------------------------------------
if [ "$MODE" = "handover" ]; then
  if [ -z "$ARG" ]; then
    fail "Usage: $0 handover <handover-id>"
    exit 1
  fi
  header "Handover Record: ${ARG}"
  query_cc "{\"function\":\"GetHandoverRecord\",\"Args\":[\"${ARG}\"]}" | fmt_json
  exit 0
fi

# ---------------------------------------------------------------------------
# Sub-command: active handovers
# ---------------------------------------------------------------------------
if [ "$MODE" = "handovers" ]; then
  header "Active Handovers"
  result=$(query_cc '{"function":"GetActiveHandovers","Args":[]}')
  if command -v jq &>/dev/null; then
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "?")
    if [ "$count" = "0" ] || [ "$count" = "null" ]; then
      info "No active handovers"
    else
      info "${count} active handover(s)"
      echo "$result" | jq -r '
        ["Handover ID","Depleted","Replacement","Phase","Initiated"],
        ["-----------","--------","-----------","-----","---------"],
        (.[] | [.handoverId, .depletedUav, (.replacementUav // "-"),
                .phase, .initiatedAt])
        | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$result" | fmt_json
    fi
  else
    echo "$result" | fmt_json
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Sub-command: handover history
# ---------------------------------------------------------------------------
if [ "$MODE" = "history" ]; then
  header "Handover History (Full Audit Trail)"
  result=$(query_cc '{"function":"GetHandoverHistory","Args":[]}')
  if command -v jq &>/dev/null; then
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "?")
    info "${count} handover record(s)"
    echo "$result" | jq -r '
      ["ID","Depleted","Replacement","Phase","Initiated","Completed","Notes"],
      ["--","--------","-----------","-----","---------","---------","-----"],
      (.[] | [.handoverId, .depletedUav, (.replacementUav // "-"),
              .phase, .initiatedAt, (.completedAt // "-"), (.notes // "-")])
      | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$result" | fmt_json
  else
    echo "$result" | fmt_json
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Sub-command: active role assignments
# ---------------------------------------------------------------------------
if [ "$MODE" = "roles" ]; then
  header "Active Role Assignments"
  result=$(query_cc '{"function":"GetActiveRoleAssignments","Args":[]}')
  if command -v jq &>/dev/null; then
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "?")
    info "${count} active assignment(s)"
    echo "$result" | jq -r '
      ["Assignment","UAV","Type","Role","Assigned At"],
      ["----------","---","----","----","-----------"],
      (.[] | [.assignmentId, .uavId, .roleType, .roleName, .assignedAt])
      | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$result" | fmt_json
  else
    echo "$result" | fmt_json
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Full report (default)
# ---------------------------------------------------------------------------
if [ "$MODE" != "full" ]; then
  fail "Unknown command: ${MODE}"
  echo ""
  echo "Usage: $0 [full|uav|status|handover|handovers|history|roles] [arg]"
  exit 1
fi

header "Digital Twin Full Report"
info "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# --- All UAVs ---
step "All UAV Descriptors"
all_uavs=$(query_cc '{"function":"GetAllUAVs","Args":[]}')

if command -v jq &>/dev/null; then
  uav_count=$(echo "$all_uavs" | jq 'length' 2>/dev/null || echo "?")
  info "Total UAVs: ${uav_count}"
  echo ""

  echo "$all_uavs" | jq -r '
    ["UAV","Status","Battery","CPU","RAM","Storage","Link","Blockchain","Service","Image"],
    ["---","------","-------","---","---","-------","----","----------","-------","-----"],
    (.[] | [.uavId, .status,
            ((.batteryLevel|tostring)+"%"),
            ((.cpuUsage|tostring)+"%"),
            ((.ramUsage|tostring)+"%"),
            ((.storageUsage|tostring)+"%"),
            ((.linkQuality|tostring)+"%"),
            .blockchainRole, .serviceRole,
            (if .assignedImage == "" then "-" else .assignedImage end)])
    | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$all_uavs" | fmt_json

  echo ""

  # Positions.
  step "UAV Positions"
  echo "$all_uavs" | jq -r '
    ["UAV","Latitude","Longitude","Altitude","Last Update"],
    ["---","--------","---------","--------","-----------"],
    (.[] | [.uavId,
            (.position.latitude|tostring),
            (.position.longitude|tostring),
            ((.position.altitude|tostring)+"m"),
            .lastUpdate])
    | @tsv' 2>/dev/null | column -t -s $'\t'

  echo ""

  # Status summary.
  step "Status Distribution"
  echo "$all_uavs" | jq -r '
    group_by(.status) | .[] |
    "  \(.[0].status): \(length) UAV(s) — \([.[].uavId] | join(", "))"
  ' 2>/dev/null
else
  echo "$all_uavs" | fmt_json
fi
echo ""

# --- Active handovers ---
step "Active Handovers"
handovers=$(query_cc '{"function":"GetActiveHandovers","Args":[]}')
if command -v jq &>/dev/null; then
  h_count=$(echo "$handovers" | jq 'length' 2>/dev/null || echo "0")
  if [ "$h_count" = "0" ] || [ "$h_count" = "null" ]; then
    info "No active handovers"
  else
    info "${h_count} active handover(s)"
    echo "$handovers" | jq -r '
      ["ID","Depleted","Replacement","Phase","Service Image"],
      ["--","--------","-----------","-----","-------------"],
      (.[] | [.handoverId, .depletedUav, (.replacementUav // "-"),
              .phase, (.serviceImage // "-")])
      | @tsv' 2>/dev/null | column -t -s $'\t'
  fi
else
  echo "$handovers" | fmt_json
fi
echo ""

# --- Active role assignments ---
step "Active Role Assignments"
roles=$(query_cc '{"function":"GetActiveRoleAssignments","Args":[]}')
if command -v jq &>/dev/null; then
  r_count=$(echo "$roles" | jq 'length' 2>/dev/null || echo "0")
  if [ "$r_count" = "0" ] || [ "$r_count" = "null" ]; then
    info "No active role assignments"
  else
    info "${r_count} active assignment(s)"
    echo "$roles" | jq -r '
      ["UAV","Type","Role","Assigned At"],
      ["---","----","----","-----------"],
      (.[] | [.uavId, .roleType, .roleName, .assignedAt])
      | @tsv' 2>/dev/null | column -t -s $'\t'
  fi
else
  echo "$roles" | fmt_json
fi
echo ""

ok "Digital Twin report complete."
