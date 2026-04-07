#!/usr/bin/env bash
# =============================================================================
# bench-02-throughput.sh — Throughput under sustained telemetry load
# =============================================================================
# Submits 20 consecutive UpdateTelemetry transactions per repetition
# (5 per UAV, cycling through UAV-001 … UAV-004 which are pre-seeded by
# InitLedger) and measures total wall-clock time and TPS.
#
# Transactions are sequential (not parallel) to measure the network's
# sustainable sequential throughput rather than burst capacity.
#
# A warm-up round is run first and excluded from the CSV.
#
# CSV output: /tmp/bench-results/bench-02-throughput.csv
# Columns: repetition,total_transactions,total_time_ms,tps
#
# Run inside cli-org1:
#   docker exec cli-org1 bash /opt/.../scripts/bench-02-throughput.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench-env.sh
source "${SCRIPT_DIR}/bench-env.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
TXNS_PER_UAV=5
UAV_IDS=("UAV-001" "UAV-002" "UAV-003" "UAV-004")
TOTAL_TXS=$(( ${#UAV_IDS[@]} * TXNS_PER_UAV ))  # 20

CSV="${BENCH_DIR}/bench-02-throughput.csv"
echo "repetition,total_transactions,total_time_ms,tps" > "${CSV}"

# ---------------------------------------------------------------------------
# Helper: run one throughput repetition
# ---------------------------------------------------------------------------
run_rep() {
  local rep="$1"
  local record="$2"

  info "[bench-02] rep=${rep}  Submitting ${TOTAL_TXS} UpdateTelemetry transactions ..." >&2

  local batch_start batch_end total_ms tps

  batch_start=$(now_ms)

  for uav_id in "${UAV_IDS[@]}"; do
    for tx in $(seq 1 "${TXNS_PER_UAV}"); do
      # Randomise telemetry values for each submission
      local bat cpu ram stor link lat lon alt
      bat=$(rand_float 10 100 2)
      cpu=$(rand_float 5 95 2)
      ram=$(rand_float 5 95 2)
      stor=$(rand_float 5 95 2)
      link=$(rand_float 50 100 2)
      lat=$(rand_float 40 42 4)
      lon=$(rand_float -5 -3 4)
      alt=$(rand_range 50 300)

      # Fire the invoke; ignore per-tx latency here — we only care about batch time
      timed_invoke "{\"function\":\"UpdateTelemetry\",\"Args\":[\"${uav_id}\",\"${bat}\",\"${cpu}\",\"${ram}\",\"${stor}\",\"${link}\",\"${lat}\",\"${lon}\",\"${alt}\"]}" > /dev/null

      if [[ ${TIMED_INVOKE_RC} -ne 0 ]]; then
        warn "[bench-02] rep=${rep}  tx ${tx} for ${uav_id} FAILED (rc=${TIMED_INVOKE_RC})" >&2
      fi
    done
  done

  batch_end=$(now_ms)
  total_ms=$((batch_end - batch_start))

  # TPS = transactions / seconds   (use awk for floating-point division)
  tps=$(awk "BEGIN { printf \"%.4f\", ${TOTAL_TXS} / (${total_ms} / 1000.0) }")

  info "[bench-02] rep=${rep}  total_ms=${total_ms}  tps=${tps}" >&2

  if [[ "${record}" == "true" ]]; then
    csv_append "${CSV}" "${rep}" "${TOTAL_TXS}" "${total_ms}" "${tps}"
    ok "[bench-02] rep=${rep} done." >&2
  else
    ok "[bench-02] warm-up done (not recorded)." >&2
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
header "Benchmark 02 — Throughput (Sequential Telemetry Load)" >&2
info "REPETITIONS=${REPETITIONS}  TXS_PER_REP=${TOTAL_TXS}  CSV=${CSV}" >&2

# Warm-up round
step "Running warm-up round ..." >&2
run_rep 0 "false"

# Measured repetitions
for rep in $(seq 1 "${REPETITIONS}"); do
  run_rep "${rep}" "true"
done

ok "bench-02-throughput complete. Results at ${CSV}" >&2
