#!/usr/bin/env bash
# =============================================================================
# bench-03-handover.sh — End-to-end handover latency (per-phase)
# =============================================================================
# Exercises the full UAV handover workflow and records the latency of each
# individual phase:
#
#   Phase 1 — InitiateHandover   (depletedUAV must be in DEPLETED status)
#   Phase 2 — SelectReplacement  (replacementUAV must be in STANDBY status)
#   Phase 3 — StartMigration
#   Phase 4 — CompleteMigration
#
# Setup steps (register, assign service, set telemetry, check depletion) are
# executed BEFORE timing starts so they do not inflate the handover numbers.
#
# A warm-up round is run first and excluded from the CSV.
#
# CSV output: /tmp/bench-results/bench-03-handover.csv
# Columns: repetition,phase,phase_name,latency_ms
#   phase=0 is the Total (sum of all four phases)
#
# Run inside cli-org1:
#   docker exec cli-org1 bash /opt/.../scripts/bench-03-handover.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench-env.sh
source "${SCRIPT_DIR}/bench-env.sh"

# ---------------------------------------------------------------------------
# Output file
# ---------------------------------------------------------------------------
CSV="${BENCH_DIR}/bench-03-handover.csv"
echo "repetition,phase,phase_name,latency_ms" > "${CSV}"

# ---------------------------------------------------------------------------
# Helper: setup — register, assign service, deplete a UAV
# ---------------------------------------------------------------------------
# Args: <dep_uav_id>  <rep_uav_id>
setup_handover() {
  local dep_uav="$1"
  local rep_uav="$2"

  info "[bench-03] setup  Registering ${dep_uav} (depleted candidate) ..." >&2
  invoke_cc_quiet "{\"function\":\"RegisterUAV\",\"Args\":[\"${dep_uav}\",\"Org1MSP\",\"SERVICE_HOST\"]}"

  info "[bench-03] setup  Registering ${rep_uav} (replacement candidate) ..." >&2
  invoke_cc_quiet "{\"function\":\"RegisterUAV\",\"Args\":[\"${rep_uav}\",\"Org2MSP\",\"STANDBY\"]}"

  # Assign a service role to the depleted UAV so StartMigration has something to transfer
  local lat lon alt
  lat=$(rand_float 40 42 4)
  lon=$(rand_float -5 -3 4)
  alt=$(rand_range 50 300)
  info "[bench-03] setup  Assigning service role to ${dep_uav} ..." >&2
  invoke_cc_quiet "{\"function\":\"AssignServiceRole\",\"Args\":[\"${dep_uav}\",\"VIDEO_STREAM\",\"docker.io/nginx:latest\",\"${lat}\",\"${lon}\",\"${alt}\"]}"

  # Set battery very low so CheckDepletionThreshold will mark it DEPLETED
  info "[bench-03] setup  Setting low battery on ${dep_uav} ..." >&2
  invoke_cc_quiet "{\"function\":\"UpdateTelemetry\",\"Args\":[\"${dep_uav}\",\"5.0\",\"20.0\",\"30.0\",\"40.0\",\"80.0\",\"${lat}\",\"${lon}\",\"${alt}\"]}"

  # Trigger depletion check with threshold=10 (battery=5 < 10 → DEPLETED)
  info "[bench-03] setup  Triggering depletion check (threshold=10) ..." >&2
  invoke_cc_quiet "{\"function\":\"CheckDepletionThreshold\",\"Args\":[\"${dep_uav}\",\"10\"]}"

  ok "[bench-03] setup  ${dep_uav} should now be DEPLETED; ${rep_uav} is STANDBY." >&2
}

# ---------------------------------------------------------------------------
# Helper: extract handover ID from GetActiveHandovers for a given depleted UAV
# ---------------------------------------------------------------------------
get_handover_id() {
  local dep_uav="$1"
  local handovers handover_id

  set +e
  handovers=$(peer chaincode query \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    -c "{\"function\":\"GetActiveHandovers\",\"Args\":[]}" \
    2>&1)
  local rc=$?
  set -e

  if [[ ${rc} -ne 0 ]]; then
    warn "[bench-03] GetActiveHandovers query failed: ${handovers}" >&2
    echo ""
    return
  fi

  # Use jq to extract the handoverId for the matching depletedUav field
  handover_id=$(echo "${handovers}" \
    | jq -r ".[] | select(.depletedUav==\"${dep_uav}\") | .handoverId" 2>/dev/null \
    | head -1)

  echo "${handover_id}"
}

# ---------------------------------------------------------------------------
# Helper: run one complete handover benchmark repetition
# ---------------------------------------------------------------------------
run_rep() {
  local rep="$1"
  local record="$2"

  local dep_uav="BENCH-HO-DEP-${rep}"
  local rep_uav="BENCH-HO-REP-${rep}"

  # ---- Setup (NOT timed) ------------------------------------------------
  setup_handover "${dep_uav}" "${rep_uav}"

  # ---- Phase 1: InitiateHandover ----------------------------------------
  info "[bench-03] rep=${rep}  Phase 1: InitiateHandover(${dep_uav}) ..." >&2
  local lat_p1
  lat_p1=$(timed_invoke "{\"function\":\"InitiateHandover\",\"Args\":[\"${dep_uav}\"]}")
  local success_p1="true"
  if [[ ${TIMED_INVOKE_RC} -ne 0 ]]; then
    warn "[bench-03] rep=${rep}  InitiateHandover FAILED (rc=${TIMED_INVOKE_RC})" >&2
    success_p1="false"
  fi

  # ---- Retrieve the handover ID ----------------------------------------
  local handover_id
  handover_id=$(get_handover_id "${dep_uav}")
  if [[ -z "${handover_id}" ]]; then
    warn "[bench-03] rep=${rep}  Could not retrieve handover ID — skipping remaining phases." >&2
    if [[ "${record}" == "true" ]]; then
      csv_append "${CSV}" "${rep}" "1" "InitiateHandover"  "${lat_p1}"
      csv_append "${CSV}" "${rep}" "2" "SelectReplacement" "N/A"
      csv_append "${CSV}" "${rep}" "3" "StartMigration"    "N/A"
      csv_append "${CSV}" "${rep}" "4" "CompleteMigration" "N/A"
      csv_append "${CSV}" "${rep}" "0" "Total"             "N/A"
    fi
    return
  fi
  info "[bench-03] rep=${rep}  Handover ID: ${handover_id}" >&2

  # ---- Phase 2: SelectReplacement ---------------------------------------
  info "[bench-03] rep=${rep}  Phase 2: SelectReplacement(${handover_id}, ${rep_uav}) ..." >&2
  local lat_p2
  lat_p2=$(timed_invoke "{\"function\":\"SelectReplacement\",\"Args\":[\"${handover_id}\",\"${rep_uav}\"]}")
  local success_p2="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_p2="false"

  # ---- Phase 3: StartMigration ------------------------------------------
  info "[bench-03] rep=${rep}  Phase 3: StartMigration(${handover_id}) ..." >&2
  local lat_p3
  lat_p3=$(timed_invoke "{\"function\":\"StartMigration\",\"Args\":[\"${handover_id}\"]}")
  local success_p3="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_p3="false"

  # ---- Phase 4: CompleteMigration ---------------------------------------
  info "[bench-03] rep=${rep}  Phase 4: CompleteMigration(${handover_id}) ..." >&2
  local lat_p4
  lat_p4=$(timed_invoke "{\"function\":\"CompleteMigration\",\"Args\":[\"${handover_id}\"]}")
  local success_p4="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_p4="false"

  # ---- Compute total ----------------------------------------------------
  # Only sum numeric values; propagate N/A if any phase failed to return a number
  local total_ms
  if [[ "${lat_p1}" =~ ^[0-9]+$ && "${lat_p2}" =~ ^[0-9]+$ && \
        "${lat_p3}" =~ ^[0-9]+$ && "${lat_p4}" =~ ^[0-9]+$ ]]; then
    total_ms=$(( lat_p1 + lat_p2 + lat_p3 + lat_p4 ))
  else
    total_ms="N/A"
  fi

  info "[bench-03] rep=${rep}  Phase latencies: p1=${lat_p1}ms p2=${lat_p2}ms p3=${lat_p3}ms p4=${lat_p4}ms total=${total_ms}ms" >&2

  # ---- Write CSV --------------------------------------------------------
  if [[ "${record}" == "true" ]]; then
    csv_append "${CSV}" "${rep}" "1" "InitiateHandover"  "${lat_p1}"
    csv_append "${CSV}" "${rep}" "2" "SelectReplacement" "${lat_p2}"
    csv_append "${CSV}" "${rep}" "3" "StartMigration"    "${lat_p3}"
    csv_append "${CSV}" "${rep}" "4" "CompleteMigration" "${lat_p4}"
    csv_append "${CSV}" "${rep}" "0" "Total"             "${total_ms}"
    ok "[bench-03] rep=${rep} done." >&2
  else
    ok "[bench-03] warm-up done (not recorded)." >&2
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
header "Benchmark 03 — Handover Latency (Per-Phase)" >&2
info "REPETITIONS=${REPETITIONS}  CSV=${CSV}" >&2

# Warm-up round
step "Running warm-up round ..." >&2
run_rep 0 "false"

# Measured repetitions
for rep in $(seq 1 "${REPETITIONS}"); do
  run_rep "${rep}" "true"
done

ok "bench-03-handover complete. Results at ${CSV}" >&2
