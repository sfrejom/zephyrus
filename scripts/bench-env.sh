#!/usr/bin/env bash
# =============================================================================
# bench-env.sh — Shared benchmark environment
# =============================================================================
# Sources sim-env.sh and extends it with timing wrappers, CSV helpers, and
# benchmark-level configuration. Source this file from every bench-XX.sh
# script instead of sourcing sim-env.sh directly.
#
# Usage (at the top of every bench-XX.sh):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/bench-env.sh"
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_ENV="${SCRIPT_DIR}/sim-env.sh"

if [[ ! -f "${SIM_ENV}" ]]; then
  echo "[bench-env] ERROR: sim-env.sh not found at ${SIM_ENV}" >&2
  exit 1
fi

# Source the existing environment and helpers
# shellcheck source=sim-env.sh
source "${SIM_ENV}"

# ---------------------------------------------------------------------------
# Benchmark-level configuration
# ---------------------------------------------------------------------------

# Directory inside the container where result CSVs are written
BENCH_DIR="/tmp/bench-results"
mkdir -p "${BENCH_DIR}"

# Number of measured repetitions (warm-up round is always run separately)
# Can be overridden from the environment before sourcing this file.
REPETITIONS="${REPETITIONS:-10}"

# ---------------------------------------------------------------------------
# CSV helper
# ---------------------------------------------------------------------------
# csv_append <file> <field1> <field2> ...
# Appends a single comma-separated line to <file>.
# Fields that contain commas should be quoted by the caller.
csv_append() {
  local file="$1"
  shift
  local IFS=','
  echo "$*" >> "${file}"
}

# ---------------------------------------------------------------------------
# timed_invoke — invoke chaincode and return ONLY the elapsed milliseconds
# ---------------------------------------------------------------------------
# Usage:
#   latency=$(timed_invoke '{"function":"Foo","Args":["bar"]}')
#   rc=$TIMED_INVOKE_RC
#
# The function always prints the latency (even on failure) so callers can
# record it. $TIMED_INVOKE_RC is set to the peer exit code.
# ---------------------------------------------------------------------------
TIMED_INVOKE_RC=0
timed_invoke() {
  local func_json="$1"
  local start end ms
  start=$(now_ms)

  # Temporarily disable errexit so a failing peer call doesn't abort the script
  set +e
  peer chaincode invoke \
    -o "${ORDERER_ADDR}" \
    --tls --cafile "${ORDERER_CA}" \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER0_ORG1_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG1_CA}" \
    --peerAddresses "${PEER0_ORG2_ADDR}" \
    --tlsRootCertFiles "${PEER0_ORG2_CA}" \
    -c "${func_json}" \
    --waitForEvent \
    > /dev/null 2>&1
  TIMED_INVOKE_RC=$?
  set -e

  end=$(now_ms)
  ms=$((end - start))
  echo "${ms}"
}

# ---------------------------------------------------------------------------
# timed_invoke_output — same as timed_invoke but also captures stdout/stderr
# ---------------------------------------------------------------------------
# Usage:
#   latency=$(timed_invoke_output '{"function":"Foo","Args":[]}' output_var)
# After the call, $output_var contains the peer command output.
# ---------------------------------------------------------------------------
timed_invoke_output() {
  local func_json="$1"
  local -n _out_var="$2"    # nameref to caller's variable
  local start end ms

  start=$(now_ms)

  set +e
  _out_var=$(peer chaincode invoke \
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
  TIMED_INVOKE_RC=$?
  set -e

  end=$(now_ms)
  ms=$((end - start))
  echo "${ms}"
}

# ---------------------------------------------------------------------------
# timed_query — query chaincode and return ONLY the elapsed milliseconds
# ---------------------------------------------------------------------------
# Usage:
#   latency=$(timed_query '{"function":"GetFoo","Args":["bar"]}')
#   rc=$TIMED_QUERY_RC
# ---------------------------------------------------------------------------
TIMED_QUERY_RC=0
timed_query() {
  local func_json="$1"
  local start end ms

  start=$(now_ms)

  set +e
  peer chaincode query \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    -c "${func_json}" \
    > /dev/null 2>&1
  TIMED_QUERY_RC=$?
  set -e

  end=$(now_ms)
  ms=$((end - start))
  echo "${ms}"
}

# ---------------------------------------------------------------------------
# timed_query_output — same but captures the query response
# ---------------------------------------------------------------------------
# Usage:
#   latency=$(timed_query_output '{"function":"GetFoo","Args":[]}' result_var)
# After the call, $result_var contains the raw JSON response string.
# ---------------------------------------------------------------------------
timed_query_output() {
  local func_json="$1"
  local -n _qout_var="$2"
  local start end ms

  start=$(now_ms)

  set +e
  _qout_var=$(peer chaincode query \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    -c "${func_json}" \
    2>&1)
  TIMED_QUERY_RC=$?
  set -e

  end=$(now_ms)
  ms=$((end - start))
  echo "${ms}"
}
