#!/usr/bin/env bash
# =============================================================================
# bench-04-mvcc.sh — MVCC conflict detection
# =============================================================================
# Tests Multi-Version Concurrency Control (MVCC) behaviour by firing two
# concurrent AssignTargetPosition invocations on the SAME UAV key.
# Because both transactions read the same key version in the same block,
# exactly one should commit and the other should fail with MVCC_READ_CONFLICT.
#
# Implementation:
#   - Both invokes run in background subshells and write their exit codes and
#     captured output to temporary files.
#   - The main process waits for both subshells, then inspects results.
#
# A warm-up round is run first and excluded from the CSV.
#
# CSV output: /tmp/bench-results/bench-04-mvcc.csv
# Columns: repetition,tx1_result,tx2_result,conflict_detected,winning_position
#
# Run inside cli-org1:
#   docker exec cli-org1 bash /opt/.../scripts/bench-04-mvcc.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench-env.sh
source "${SCRIPT_DIR}/bench-env.sh"

# ---------------------------------------------------------------------------
# Output file
# ---------------------------------------------------------------------------
CSV="${BENCH_DIR}/bench-04-mvcc.csv"
echo "repetition,tx1_result,tx2_result,conflict_detected,winning_position" > "${CSV}"

# ---------------------------------------------------------------------------
# Helper: classify a peer invoke output as COMMITTED or MVCC_READ_CONFLICT
# ---------------------------------------------------------------------------
classify_output() {
  local output="$1"
  local rc="$2"

  if [[ ${rc} -eq 0 ]]; then
    echo "COMMITTED"
  elif echo "${output}" | grep -qi "MVCC_READ_CONFLICT"; then
    echo "MVCC_READ_CONFLICT"
  elif echo "${output}" | grep -qi "PHANTOM_READ_CONFLICT"; then
    echo "PHANTOM_READ_CONFLICT"
  else
    echo "FAILED(rc=${rc})"
  fi
}

# ---------------------------------------------------------------------------
# Helper: fire a single concurrent invoke and write results to temp files
# ---------------------------------------------------------------------------
# Args: <func_json> <out_file> <rc_file>
fire_invoke_bg() {
  local func_json="$1"
  local out_file="$2"
  local rc_file="$3"

  (
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
      --waitForEvent \
      2>&1)
    rc=$?
    echo "${output}" > "${out_file}"
    echo "${rc}"     > "${rc_file}"
  ) &
}

# ---------------------------------------------------------------------------
# Helper: run one MVCC repetition
# ---------------------------------------------------------------------------
run_rep() {
  local rep="$1"
  local record="$2"

  local uav_id="BENCH-MVCC-${rep}"

  # ---- Register fresh test UAV (not timed) ------------------------------
  info "[bench-04] rep=${rep}  Registering UAV ${uav_id} ..." >&2
  invoke_cc_quiet "{\"function\":\"RegisterUAV\",\"Args\":[\"${uav_id}\",\"Org1MSP\",\"SENSOR\"]}"

  # Give the ledger a moment to settle before firing concurrent txns
  sleep 0.5

  # ---- Generate two distinct target positions ---------------------------
  local lat1 lon1 alt1 lat2 lon2 alt2
  lat1=$(rand_float 40 41 4)
  lon1=$(rand_float -5 -4 4)
  alt1=$(rand_range 50 150)
  lat2=$(rand_float 41 42 4)
  lon2=$(rand_float -4 -3 4)
  alt2=$(rand_range 150 300)

  local func1="{\"function\":\"AssignTargetPosition\",\"Args\":[\"${uav_id}\",\"${lat1}\",\"${lon1}\",\"${alt1}\"]}"
  local func2="{\"function\":\"AssignTargetPosition\",\"Args\":[\"${uav_id}\",\"${lat2}\",\"${lon2}\",\"${alt2}\"]}"

  # ---- Temp files for background results --------------------------------
  local tmp_out1 tmp_rc1 tmp_out2 tmp_rc2
  tmp_out1=$(mktemp /tmp/bench04-tx1-out.XXXXXX)
  tmp_rc1=$(mktemp  /tmp/bench04-tx1-rc.XXXXXX)
  tmp_out2=$(mktemp /tmp/bench04-tx2-out.XXXXXX)
  tmp_rc2=$(mktemp  /tmp/bench04-tx2-rc.XXXXXX)

  # ---- Fire both transactions concurrently ------------------------------
  info "[bench-04] rep=${rep}  Firing two concurrent AssignTargetPosition invocations ..." >&2
  fire_invoke_bg "${func1}" "${tmp_out1}" "${tmp_rc1}"
  fire_invoke_bg "${func2}" "${tmp_out2}" "${tmp_rc2}"

  # Wait for both background subshells to complete
  wait

  # ---- Read results -----------------------------------------------------
  local out1 rc1 out2 rc2
  out1=$(cat "${tmp_out1}")
  rc1=$(cat  "${tmp_rc1}")
  out2=$(cat "${tmp_out2}")
  rc2=$(cat  "${tmp_rc2}")

  # Clean up temp files
  rm -f "${tmp_out1}" "${tmp_rc1}" "${tmp_out2}" "${tmp_rc2}"

  # ---- Classify outcomes ------------------------------------------------
  local result1 result2
  result1=$(classify_output "${out1}" "${rc1}")
  result2=$(classify_output "${out2}" "${rc2}")

  info "[bench-04] rep=${rep}  tx1=${result1}  tx2=${result2}" >&2

  # ---- Determine conflict and winning position --------------------------
  local conflict_detected="false"
  local winning_position="N/A"

  if [[ "${result1}" == "MVCC_READ_CONFLICT" || "${result2}" == "MVCC_READ_CONFLICT" ]]; then
    conflict_detected="true"
  fi

  if [[ "${result1}" == "COMMITTED" && "${result2}" != "COMMITTED" ]]; then
    winning_position="${lat1}/${lon1}/${alt1}"
  elif [[ "${result2}" == "COMMITTED" && "${result1}" != "COMMITTED" ]]; then
    winning_position="${lat2}/${lon2}/${alt2}"
  elif [[ "${result1}" == "COMMITTED" && "${result2}" == "COMMITTED" ]]; then
    # Both committed — no MVCC conflict occurred (can happen if they landed in different blocks)
    winning_position="both_committed"
  fi

  info "[bench-04] rep=${rep}  conflict_detected=${conflict_detected}  winning_position=${winning_position}" >&2

  # ---- Write CSV --------------------------------------------------------
  if [[ "${record}" == "true" ]]; then
    csv_append "${CSV}" "${rep}" "${result1}" "${result2}" "${conflict_detected}" "${winning_position}"
    ok "[bench-04] rep=${rep} done." >&2
  else
    ok "[bench-04] warm-up done (not recorded)." >&2
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
header "Benchmark 04 — MVCC Conflict Detection" >&2
info "REPETITIONS=${REPETITIONS}  CSV=${CSV}" >&2

# Warm-up round
step "Running warm-up round ..." >&2
run_rep 0 "false"

# Measured repetitions
for rep in $(seq 1 "${REPETITIONS}"); do
  run_rep "${rep}" "true"
done

ok "bench-04-mvcc complete. Results at ${CSV}" >&2
