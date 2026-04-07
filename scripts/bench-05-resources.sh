#!/usr/bin/env bash
# ===========================================================================
# bench-05-resources.sh — Resource monitoring during benchmark execution.
#
# Runs ON THE HOST (each Raspberry Pi), NOT inside a Docker container.
# Samples docker stats + system-level /proc metrics every INTERVAL seconds
# and writes to a CSV file.
#
# Usage (on any Pi):
#   ./scripts/bench-05-resources.sh [interval_seconds] [output_csv]
#
# To stop: Ctrl-C or send SIGTERM (the script traps it and exits cleanly).
#
# Designed to run in background on ALL Pis while benchmarks execute:
#   ssh spilab@uav-1.local "./scripts/bench-05-resources.sh 2 /tmp/resources-uav1.csv" &
#   ssh spilab@uav-2.local "./scripts/bench-05-resources.sh 2 /tmp/resources-uav2.csv" &
#   ssh spilab@uav-3.local "./scripts/bench-05-resources.sh 2 /tmp/resources-uav3.csv" &
#   ssh spilab@uav-4.local "./scripts/bench-05-resources.sh 2 /tmp/resources-uav4.csv" &
# ===========================================================================
set -uo pipefail

INTERVAL="${1:-2}"
OUTPUT="${2:-/tmp/bench-resources-$(hostname).csv}"
HOSTNAME_TAG=$(hostname)

# -------------------------------------------------------------------------
# Header
# -------------------------------------------------------------------------
echo "timestamp,hostname,metric_source,container,cpu_percent,mem_usage_mb,mem_limit_mb,mem_percent,net_rx_mb,net_tx_mb" \
  > "${OUTPUT}"

echo "[monitor] Sampling every ${INTERVAL}s → ${OUTPUT}" >&2
echo "[monitor] Press Ctrl-C to stop." >&2

# -------------------------------------------------------------------------
# Trap SIGINT/SIGTERM for clean exit
# -------------------------------------------------------------------------
RUNNING=true
cleanup() {
  RUNNING=false
  echo "" >&2
  echo "[monitor] Stopped. $(wc -l < "${OUTPUT}") samples written to ${OUTPUT}" >&2
}
trap cleanup INT TERM

# -------------------------------------------------------------------------
# Helper: parse "1.234GiB" / "45.6MiB" / "123kB" → MB float
# -------------------------------------------------------------------------
to_mb() {
  local val="$1"
  if [[ "$val" == *GiB* ]]; then
    echo "$val" | sed 's/GiB//' | awk '{printf "%.2f", $1 * 1024}'
  elif [[ "$val" == *MiB* ]]; then
    echo "$val" | sed 's/MiB//' | awk '{printf "%.2f", $1}'
  elif [[ "$val" == *KiB* ]] || [[ "$val" == *kB* ]]; then
    echo "$val" | sed 's/[KkiB]*//g' | awk '{printf "%.2f", $1 / 1024}'
  elif [[ "$val" == *B* ]]; then
    echo "$val" | sed 's/B//' | awk '{printf "%.4f", $1 / 1048576}'
  else
    echo "0.00"
  fi
}

# -------------------------------------------------------------------------
# Helper: parse "1.45MB / 892kB" → two MB values
# -------------------------------------------------------------------------
parse_net_io() {
  local raw="$1"
  local rx_raw tx_raw
  rx_raw=$(echo "$raw" | awk -F'/' '{print $1}' | xargs)
  tx_raw=$(echo "$raw" | awk -F'/' '{print $2}' | xargs)
  local rx_mb tx_mb
  rx_mb=$(to_mb "$rx_raw")
  tx_mb=$(to_mb "$tx_raw")
  echo "${rx_mb},${tx_mb}"
}

# -------------------------------------------------------------------------
# Helper: system-wide metrics from /proc (not per-container)
# -------------------------------------------------------------------------
sample_system() {
  local ts="$1"

  # CPU usage: read /proc/stat, compute since last sample
  # We'll use a simpler approach: overall CPU % from /proc/stat
  local cpu_line idle_val total_val cpu_pct
  cpu_line=$(head -1 /proc/stat)
  # cpu  user nice system idle iowait irq softirq steal
  local user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal <<< "$cpu_line"
  total_val=$((user + nice + system + idle + iowait + irq + softirq + steal))

  if [[ -n "${PREV_TOTAL:-}" ]]; then
    local d_total=$((total_val - PREV_TOTAL))
    local d_idle=$((idle - PREV_IDLE))
    if [[ $d_total -gt 0 ]]; then
      cpu_pct=$(awk "BEGIN {printf \"%.1f\", (1 - ${d_idle}/${d_total}) * 100}")
    else
      cpu_pct="0.0"
    fi
  else
    cpu_pct="0.0"
  fi
  PREV_TOTAL=$total_val
  PREV_IDLE=$idle

  # Memory from /proc/meminfo
  local mem_total_kb mem_avail_kb mem_used_mb mem_total_mb mem_pct
  mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  mem_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  mem_used_mb=$(awk "BEGIN {printf \"%.1f\", (${mem_total_kb} - ${mem_avail_kb}) / 1024}")
  mem_total_mb=$(awk "BEGIN {printf \"%.1f\", ${mem_total_kb} / 1024}")
  mem_pct=$(awk "BEGIN {printf \"%.1f\", (${mem_total_kb} - ${mem_avail_kb}) / ${mem_total_kb} * 100}")

  echo "${ts},${HOSTNAME_TAG},system,_host_,${cpu_pct},${mem_used_mb},${mem_total_mb},${mem_pct},0.00,0.00" \
    >> "${OUTPUT}"
}

# -------------------------------------------------------------------------
# Helper: per-container metrics from docker stats
# -------------------------------------------------------------------------
sample_containers() {
  local ts="$1"

  # docker stats --no-stream: one-shot snapshot
  # Format: Name, CPUPerc, MemUsage, MemPerc, NetIO
  local stats_output
  stats_output=$(docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}}" 2>/dev/null) || return

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local name cpu_pct mem_usage_raw mem_pct net_io_raw
    name=$(echo "$line" | awk -F',' '{print $1}')
    cpu_pct=$(echo "$line" | awk -F',' '{print $2}' | tr -d '%')
    mem_usage_raw=$(echo "$line" | awk -F',' '{print $3}')
    mem_pct=$(echo "$line" | awk -F',' '{print $4}' | tr -d '%')
    net_io_raw=$(echo "$line" | awk -F',' '{print $5}')

    # Parse "45.2MiB / 512MiB" → usage_mb, limit_mb
    local usage_raw limit_raw usage_mb limit_mb
    usage_raw=$(echo "$mem_usage_raw" | awk -F'/' '{print $1}' | xargs)
    limit_raw=$(echo "$mem_usage_raw" | awk -F'/' '{print $2}' | xargs)
    usage_mb=$(to_mb "$usage_raw")
    limit_mb=$(to_mb "$limit_raw")

    # Parse net I/O
    local net_vals
    net_vals=$(parse_net_io "$net_io_raw")

    echo "${ts},${HOSTNAME_TAG},docker,${name},${cpu_pct},${usage_mb},${limit_mb},${mem_pct},${net_vals}" \
      >> "${OUTPUT}"
  done <<< "$stats_output"
}

# -------------------------------------------------------------------------
# Main sampling loop
# -------------------------------------------------------------------------
PREV_TOTAL=""
PREV_IDLE=""

# First sample to initialize CPU delta baseline
sample_system "$(date -u +%Y-%m-%dT%H:%M:%S)" > /dev/null 2>&1
sleep 0.5

while $RUNNING; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%S)
  sample_system  "$ts"
  sample_containers "$ts"
  sleep "${INTERVAL}" &
  wait $! 2>/dev/null || true
done
