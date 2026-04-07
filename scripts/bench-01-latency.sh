#!/usr/bin/env bash
# =============================================================================
# bench-01-latency.sh — Transaction latency by function type
# =============================================================================
# Measures the end-to-end latency (client submission → block commit) for each
# chaincode function type across REPETITIONS iterations.
#
# For each repetition a unique test UAV is registered so every invoke operates
# on fresh state and we avoid inter-rep interference.
#
# A warm-up round (rep=0) is executed first and excluded from the CSV so that
# JVM/peer connection cold-start effects are not captured.
#
# CSV output: /tmp/bench-results/bench-01-latency.csv
# Columns: repetition,function,type,latency_ms,success
#
# Run inside cli-org1:
#   docker exec cli-org1 bash /opt/.../scripts/bench-01-latency.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench-env.sh
source "${SCRIPT_DIR}/bench-env.sh"

# ---------------------------------------------------------------------------
# Output file
# ---------------------------------------------------------------------------
CSV="${BENCH_DIR}/bench-01-latency.csv"
# Write header (overwrite any previous run)
echo "repetition,function,type,latency_ms,success" > "${CSV}"

# ---------------------------------------------------------------------------
# Helper: run one full repetition for a given UAV and (optionally) record it
# ---------------------------------------------------------------------------
# Args: <rep_number> <uav_id> <record: true|false>
run_rep() {
  local rep="$1"
  local uav_id="$2"
  local record="$3"

  # ---- 1. Register the test UAV ----------------------------------------
  # We always register at the start of every rep (including warm-up) so the
  # UAV exists when we measure the other functions. Registration time itself
  # is NOT included in per-function measurements.
  info "[bench-01] rep=${rep}  Registering UAV ${uav_id} ..." >&2
  invoke_cc_quiet "{\"function\":\"RegisterUAV\",\"Args\":[\"${uav_id}\",\"Org1MSP\",\"SENSOR\"]}"

  # ---- 2. UpdateTelemetry -----------------------------------------------
  local bat cpu ram stor link lat lon alt
  bat=$(rand_float 10 100 2)
  cpu=$(rand_float 5 95 2)
  ram=$(rand_float 5 95 2)
  stor=$(rand_float 5 95 2)
  link=$(rand_float 50 100 2)
  lat=$(rand_float 40 42 4)
  lon=$(rand_float -5 -3 4)
  alt=$(rand_range 50 300)

  info "[bench-01] rep=${rep}  Measuring UpdateTelemetry ..." >&2
  local lat_upd
  lat_upd=$(timed_invoke "{\"function\":\"UpdateTelemetry\",\"Args\":[\"${uav_id}\",\"${bat}\",\"${cpu}\",\"${ram}\",\"${stor}\",\"${link}\",\"${lat}\",\"${lon}\",\"${alt}\"]}")
  local success_upd="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_upd="false"

  # ---- 3. AssignServiceRole ---------------------------------------------
  local svc_lat svc_lon svc_alt
  svc_lat=$(rand_float 40 42 4)
  svc_lon=$(rand_float -5 -3 4)
  svc_alt=$(rand_range 50 300)

  info "[bench-01] rep=${rep}  Measuring AssignServiceRole ..." >&2
  local lat_svc
  lat_svc=$(timed_invoke "{\"function\":\"AssignServiceRole\",\"Args\":[\"${uav_id}\",\"VIDEO_STREAM\",\"docker.io/nginx:latest\",\"${svc_lat}\",\"${svc_lon}\",\"${svc_alt}\"]}")
  local success_svc="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_svc="false"

  # ---- 4. RevokeServiceRole ---------------------------------------------
  info "[bench-01] rep=${rep}  Measuring RevokeServiceRole ..." >&2
  local lat_rev
  lat_rev=$(timed_invoke "{\"function\":\"RevokeServiceRole\",\"Args\":[\"${uav_id}\"]}")
  local success_rev="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_rev="false"

  # ---- 5. AssignBlockchainRole ------------------------------------------
  info "[bench-01] rep=${rep}  Measuring AssignBlockchainRole ..." >&2
  local lat_bcr
  lat_bcr=$(timed_invoke "{\"function\":\"AssignBlockchainRole\",\"Args\":[\"${uav_id}\",\"VALIDATOR\"]}")
  local success_bcr="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_bcr="false"

  # ---- 6. AssignTargetPosition ------------------------------------------
  local tgt_lat tgt_lon tgt_alt
  tgt_lat=$(rand_float 40 42 4)
  tgt_lon=$(rand_float -5 -3 4)
  tgt_alt=$(rand_range 50 300)

  info "[bench-01] rep=${rep}  Measuring AssignTargetPosition ..." >&2
  local lat_pos
  lat_pos=$(timed_invoke "{\"function\":\"AssignTargetPosition\",\"Args\":[\"${uav_id}\",\"${tgt_lat}\",\"${tgt_lon}\",\"${tgt_alt}\"]}")
  local success_pos="true"; [[ ${TIMED_INVOKE_RC} -ne 0 ]] && success_pos="false"

  # ---- 7. GetUAVState query ---------------------------------------------
  info "[bench-01] rep=${rep}  Measuring GetUAVState (query) ..." >&2
  local lat_get
  lat_get=$(timed_query "{\"function\":\"GetUAVState\",\"Args\":[\"${uav_id}\"]}")
  local success_get="true"; [[ ${TIMED_QUERY_RC} -ne 0 ]] && success_get="false"

  # ---- 8. GetAllUAVs query ----------------------------------------------
  info "[bench-01] rep=${rep}  Measuring GetAllUAVs (query) ..." >&2
  local lat_all
  lat_all=$(timed_query "{\"function\":\"GetAllUAVs\",\"Args\":[]}")
  local success_all="true"; [[ ${TIMED_QUERY_RC} -ne 0 ]] && success_all="false"

  # ---- Record results (skip for warm-up round) --------------------------
  if [[ "${record}" == "true" ]]; then
    csv_append "${CSV}" "${rep}" "UpdateTelemetry"    "invoke" "${lat_upd}" "${success_upd}"
    csv_append "${CSV}" "${rep}" "AssignServiceRole"  "invoke" "${lat_svc}" "${success_svc}"
    csv_append "${CSV}" "${rep}" "RevokeServiceRole"  "invoke" "${lat_rev}" "${success_rev}"
    csv_append "${CSV}" "${rep}" "AssignBlockchainRole" "invoke" "${lat_bcr}" "${success_bcr}"
    csv_append "${CSV}" "${rep}" "AssignTargetPosition" "invoke" "${lat_pos}" "${success_pos}"
    csv_append "${CSV}" "${rep}" "GetUAVState"        "query"  "${lat_get}" "${success_get}"
    csv_append "${CSV}" "${rep}" "GetAllUAVs"         "query"  "${lat_all}" "${success_all}"
    ok "[bench-01] rep=${rep} done." >&2
  else
    ok "[bench-01] warm-up done (not recorded)." >&2
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
header "Benchmark 01 — Transaction Latency" >&2
info "REPETITIONS=${REPETITIONS}  CSV=${CSV}" >&2

# Warm-up round (rep 0) — results discarded
step "Running warm-up round ..." >&2
run_rep 0 "BENCH-01-WARMUP" "false"

# Measured repetitions
for rep in $(seq 1 "${REPETITIONS}"); do
  UAV_ID="BENCH-01-R${rep}"
  run_rep "${rep}" "${UAV_ID}" "true"
done

ok "bench-01-latency complete. Results at ${CSV}" >&2
