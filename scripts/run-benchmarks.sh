#!/usr/bin/env bash
# =============================================================================
# run-benchmarks.sh — Master benchmark orchestrator (runs on UAV-1 HOST)
# =============================================================================
# Executes the full benchmark suite against cli-org1 running on UAV-2,
# monitors resource usage on all Pis, collects CSV results, and prints
# a summary.
#
# Usage:
#   ./scripts/run-benchmarks.sh [repetitions]
#
# Arguments:
#   repetitions   Number of measured repetitions for each benchmark (default 10)
#
# Dependencies:
#   - env.sh must be present in the same directory (sets SPILAB_HOME, SSH_USER,
#     SSH_PASS, SSH_OPTS, remote_exec, etc.)
#   - jq must be available on the host for the final summary table
#
# What it does:
#   1. Sources env.sh for SSH configuration
#   2. Creates a timestamped results directory: ~/uav-fabric-network/results/<ts>/
#   3. Runs a connectivity check (GetAllUAVs query) via docker exec on UAV-2
#   4. Runs bench-01 … bench-04 sequentially on UAV-2
#   5. Copies each CSV from the container → UAV-2 host → UAV-1 host
#   6. Starts resource monitors (bench-05) on all Pis in background
#   7. After benchmarks, stops monitors and collects resource CSVs
#   8. Prints a summary of collected files
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory and source env.sh
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[run-benchmarks] ERROR: env.sh not found at ${ENV_FILE}" >&2
  exit 1
fi

# shellcheck source=env.sh
source "${ENV_FILE}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPETITIONS="${1:-10}"          # Accept as first positional argument

UAV2_HOST="${UAV2_HOST:-uav-2.local}"
UAV2_USER="${SSH_USER:-spilab}"
CONTAINER="cli-org1"
SCRIPTS_INSIDE="/opt/gopath/src/github.com/hyperledger/fabric/peer/scripts"
BENCH_DIR_INSIDE="/tmp/bench-results"   # Where bench scripts write CSVs

# Local results directory (timestamped)
RESULTS_BASE="${SPILAB_HOME:-$HOME}/uav-fabric-network/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${RESULTS_BASE}/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

# Benchmarks to run (in order)
BENCHMARKS=(
  "bench-01-latency"
  "bench-02-throughput"
  "bench-03-handover"
  "bench-04-mvcc"
)

# ---------------------------------------------------------------------------
# Logging helpers (simple, no dependency on sim-env.sh since we're on host)
# ---------------------------------------------------------------------------
_log()  { echo "[$(date +%H:%M:%S)] $*"; }
_ok()   { echo "[$(date +%H:%M:%S)] ✓ $*"; }
_warn() { echo "[$(date +%H:%M:%S)] ⚠ $*" >&2; }
_fail() { echo "[$(date +%H:%M:%S)] ✗ $*" >&2; exit 1; }
_sep()  { echo "────────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
# remote_exec wrapper — uses the function from env.sh if available, otherwise
# falls back to a plain ssh invocation.
# ---------------------------------------------------------------------------
# Signature: run_remote <command_string>
run_remote() {
  local cmd="$1"
  if declare -f remote_exec &>/dev/null; then
    # Use the project's existing helper
    remote_exec "${UAV2_HOST}" "${cmd}"
  else
    # Fallback: direct ssh
    # shellcheck disable=SC2029
    ssh ${SSH_OPTS:-"-o StrictHostKeyChecking=no"} \
        "${UAV2_USER}@${UAV2_HOST}" \
        "${cmd}"
  fi
}

# Signature: run_remote_host <host> <command_string>
run_remote_host() {
  local host="$1" cmd="$2"
  if declare -f remote_exec &>/dev/null; then
    remote_exec "${host}" "${cmd}"
  else
    ssh ${SSH_OPTS:-"-o StrictHostKeyChecking=no"} \
        "${SSH_USER:-spilab}@${host}" \
        "${cmd}"
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — Print run configuration
# ---------------------------------------------------------------------------
_sep
_log "UAV Fabric Benchmark Suite"
_log "Target host   : ${UAV2_USER}@${UAV2_HOST}"
_log "Container     : ${CONTAINER}"
_log "Repetitions   : ${REPETITIONS}"
_log "Results dir   : ${RESULTS_DIR}"
_sep

# ---------------------------------------------------------------------------
# Step 2 — Connectivity check
# ---------------------------------------------------------------------------
_log "Running connectivity check (GetAllUAVs query) ..."

set +e
connectivity_output=$(run_remote \
  "docker exec ${CONTAINER} peer chaincode query \
     -C \"\${CHANNEL_NAME:-uav-channel}\" \
     -n \"\${CC_NAME:-uavcc}\" \
     -c '{\"function\":\"GetAllUAVs\",\"Args\":[]}' 2>&1")
connectivity_rc=$?
set -e

if [[ ${connectivity_rc} -ne 0 ]]; then
  _fail "Connectivity check FAILED. Is the Fabric network up?\n${connectivity_output}"
fi

# Count returned UAVs (best-effort; don't fail if jq unavailable on host)
if command -v jq &>/dev/null; then
  uav_count=$(echo "${connectivity_output}" | jq '. | length' 2>/dev/null || echo "?")
  _ok "Connectivity OK. Ledger reports ${uav_count} UAV(s)."
else
  _ok "Connectivity OK (jq not available — cannot count UAVs)."
fi

# ---------------------------------------------------------------------------
# Step 3 — Ensure bench-results directory exists in the container
# ---------------------------------------------------------------------------
_log "Ensuring ${BENCH_DIR_INSIDE} exists inside ${CONTAINER} ..."
run_remote "docker exec ${CONTAINER} mkdir -p ${BENCH_DIR_INSIDE}"

# ---------------------------------------------------------------------------
# Step 4 — Run each benchmark
# ---------------------------------------------------------------------------
FAILED_BENCHMARKS=()

for bench in "${BENCHMARKS[@]}"; do
  _sep
  _log "Running ${bench} (REPETITIONS=${REPETITIONS}) ..."

  set +e
  run_remote \
    "REPETITIONS=${REPETITIONS} docker exec \
       -e REPETITIONS=${REPETITIONS} \
       ${CONTAINER} \
       bash ${SCRIPTS_INSIDE}/${bench}.sh"
  bench_rc=$?
  set -e

  if [[ ${bench_rc} -ne 0 ]]; then
    _warn "${bench} exited with rc=${bench_rc}. CSV may be incomplete."
    FAILED_BENCHMARKS+=("${bench}")
  else
    _ok "${bench} completed."
  fi

  # ---- Copy CSV out of the container to the host -----------------------
  CSV_NAME="${bench}.csv"
  TMP_ON_UAV2="/tmp/${CSV_NAME}"

  _log "Copying ${CSV_NAME} from container to UAV-2 host ..."
  set +e
  run_remote "docker cp ${CONTAINER}:${BENCH_DIR_INSIDE}/${CSV_NAME} ${TMP_ON_UAV2}"
  cp_rc=$?
  set -e

  if [[ ${cp_rc} -ne 0 ]]; then
    _warn "Failed to copy ${CSV_NAME} from container (rc=${cp_rc})."
    continue
  fi

  _log "Fetching ${CSV_NAME} from UAV-2 to local results directory ..."
  set +e
  scp ${SSH_OPTS:-"-o StrictHostKeyChecking=no"} \
      "${UAV2_USER}@${UAV2_HOST}:${TMP_ON_UAV2}" \
      "${RESULTS_DIR}/${CSV_NAME}"
  scp_rc=$?
  set -e

  if [[ ${scp_rc} -ne 0 ]]; then
    _warn "scp of ${CSV_NAME} failed (rc=${scp_rc})."
  else
    _ok "${CSV_NAME} saved to ${RESULTS_DIR}/${CSV_NAME}"
  fi

  # Clean up the temp file on UAV-2
  run_remote "rm -f ${TMP_ON_UAV2}" || true
done

# ---------------------------------------------------------------------------
# Step 5 — Stop resource monitors and collect CSVs
# ---------------------------------------------------------------------------
_sep
_log "Stopping resource monitors on all Pis ..."

for host in "${UAV1_HOST}" "${UAV2_HOST}" "${UAV3_HOST}" "${UAV4_HOST}"; do
  run_remote_host "${host}" "pkill -f bench-05-resources.sh" 2>/dev/null || true
done
sleep 2

for host in "${UAV1_HOST}" "${UAV2_HOST}" "${UAV3_HOST}" "${UAV4_HOST}"; do
  host_short=$(echo "${host}" | sed 's/.local//')
  csv_name="bench-05-resources-${host_short}.csv"
  _log "Fetching resource metrics from ${host} ..."
  set +e
  scp ${SSH_OPTS:-"-o StrictHostKeyChecking=no"} \
      "${SSH_USER}@${host}:/tmp/bench-resources-*.csv" \
      "${RESULTS_DIR}/${csv_name}" 2>/dev/null
  set -e
done

# ---------------------------------------------------------------------------
# Step 6 — Print summary
# ---------------------------------------------------------------------------
_sep
_log "Benchmark Suite Complete"
_sep
echo ""
echo "Results directory: ${RESULTS_DIR}"
echo ""

shopt -s nullglob
csv_files=("${RESULTS_DIR}"/*.csv)

if [[ ${#csv_files[@]} -eq 0 ]]; then
  _warn "No CSV files found in ${RESULTS_DIR}."
else
  echo "Collected CSVs:"
  for f in "${csv_files[@]}"; do
    lines=$(wc -l < "${f}" 2>/dev/null || echo "?")
    # Subtract 1 for the header row
    data_lines=$(( lines > 0 ? lines - 1 : 0 ))
    printf "  %-40s  %d data rows\n" "$(basename "${f}")" "${data_lines}"
  done
fi
echo ""

if [[ ${#FAILED_BENCHMARKS[@]} -gt 0 ]]; then
  _warn "The following benchmarks reported errors:"
  for b in "${FAILED_BENCHMARKS[@]}"; do
    echo "    - ${b}"
  done
  echo "  Check container logs: docker logs ${CONTAINER}"
  echo ""
fi

_sep

# Exit with non-zero if any benchmark failed
if [[ ${#FAILED_BENCHMARKS[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
