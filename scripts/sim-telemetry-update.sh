#!/usr/bin/env bash
# =============================================================================
# sim-telemetry-update.sh — Simulate periodic telemetry updates from 4 UAVs
#
# Each round sends an UpdateTelemetry transaction for every UAV, with battery
# gradually decreasing and CPU/RAM/storage/link-quality fluctuating randomly.
# After each round the full Digital Twin state is queried and displayed.
#
# Usage: ./sim-telemetry-update.sh [rounds]     (default: 5)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sim-env.sh"

ROUNDS=${1:-5}

# ---------------------------------------------------------------------------
# Initial telemetry state per UAV (battery drains each round)
# ---------------------------------------------------------------------------
declare -A BAT CPU RAM STOR LINK LAT LON ALT

BAT[UAV-001]=100  BAT[UAV-002]=100  BAT[UAV-003]=100  BAT[UAV-004]=100
CPU[UAV-001]=15   CPU[UAV-002]=20   CPU[UAV-003]=18   CPU[UAV-004]=5
RAM[UAV-001]=30   RAM[UAV-002]=35   RAM[UAV-003]=32   RAM[UAV-004]=10
STOR[UAV-001]=20  STOR[UAV-002]=25  STOR[UAV-003]=22  STOR[UAV-004]=10
LINK[UAV-001]=95  LINK[UAV-002]=90  LINK[UAV-003]=92  LINK[UAV-004]=88

# Positions near a simulated mission area (Madrid coordinates)
LAT[UAV-001]=40.4168  LAT[UAV-002]=40.4170  LAT[UAV-003]=40.4172  LAT[UAV-004]=40.4174
LON[UAV-001]=-3.7038  LON[UAV-002]=-3.7040  LON[UAV-003]=-3.7042  LON[UAV-004]=-3.7044
ALT[UAV-001]=50       ALT[UAV-002]=50       ALT[UAV-003]=50       ALT[UAV-004]=0

UAVS=("UAV-001" "UAV-002" "UAV-003" "UAV-004")

header "UAV Swarm Telemetry Simulation"
info "Rounds     : ${ROUNDS}"
info "UAVs       : ${UAVS[*]}"
info "Channel    : ${CHANNEL_NAME}"
info "Chaincode  : ${CC_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Simulation loop
# ---------------------------------------------------------------------------
for (( r=1; r<=ROUNDS; r++ )); do
  header "Round ${r} / ${ROUNDS}"

  for uav in "${UAVS[@]}"; do
    # --- Simulate telemetry drift ---
    # Battery drains 3-8% per round.
    drain=$(rand_range 3 8)
    BAT[$uav]=$(( ${BAT[$uav]} - drain ))
    if [ "${BAT[$uav]}" -lt 0 ]; then BAT[$uav]=0; fi

    # CPU/RAM fluctuate ±5.
    CPU[$uav]=$(rand_range $(( ${CPU[$uav]} > 5  ? ${CPU[$uav]} - 5  : 1 )) \
                           $(( ${CPU[$uav]} < 95 ? ${CPU[$uav]} + 5  : 99 )) )
    RAM[$uav]=$(rand_range $(( ${RAM[$uav]} > 5  ? ${RAM[$uav]} - 5  : 1 )) \
                           $(( ${RAM[$uav]} < 95 ? ${RAM[$uav]} + 5  : 99 )) )

    # Storage creeps up slowly.
    STOR[$uav]=$(( ${STOR[$uav]} + $(rand_range 0 2) ))
    if [ "${STOR[$uav]}" -gt 99 ]; then STOR[$uav]=99; fi

    # Link quality fluctuates ±3.
    LINK[$uav]=$(rand_range $(( ${LINK[$uav]} > 3   ? ${LINK[$uav]} - 3  : 1 )) \
                            $(( ${LINK[$uav]} < 100 ? ${LINK[$uav]} + 3  : 100 )) )

    # Small position drift (simulate movement).
    lat_frac=$(rand_range 0 9)
    lon_frac=$(rand_range 0 9)
    alt_delta=$(rand_range -2 2)
    new_alt=$(( ${ALT[$uav]} + alt_delta ))
    if [ "$new_alt" -lt 0 ]; then new_alt=0; fi
    ALT[$uav]=$new_alt

    # Build the invoke JSON.
    args="\"${uav}\",\"${BAT[$uav]}.0\",\"${CPU[$uav]}.${lat_frac}\",\"${RAM[$uav]}.0\",\"${STOR[$uav]}.0\",\"${LINK[$uav]}.0\",\"${LAT[$uav]}${lat_frac}\",\"${LON[$uav]}${lon_frac}\",\"${ALT[$uav]}.0\""
    func_json="{\"function\":\"UpdateTelemetry\",\"Args\":[${args}]}"

    step "Updating ${uav}  bat=${BAT[$uav]}%  cpu=${CPU[$uav]}%  ram=${RAM[$uav]}%  link=${LINK[$uav]}%  alt=${ALT[$uav]}m"
    invoke_cc "${func_json}" > /dev/null
  done

  # --- Query and display current DT state ---
  step "Querying Digital Twin state..."
  result=$(query_cc '{"function":"GetAllUAVs","Args":[]}')

  if command -v jq &>/dev/null; then
    echo "$result" | jq -r '
      ["UAV ID","Status","Battery","CPU","RAM","Link","Blockchain","Service"],
      ["------","------","-------","---","---","----","----------","-------"],
      (.[] | [.uavId, .status,
              (.batteryLevel | tostring)+"%",
              (.cpuUsage | tostring)+"%",
              (.ramUsage | tostring)+"%",
              (.linkQuality | tostring)+"%",
              .blockchainRole, .serviceRole])
      | @tsv' 2>/dev/null | column -t -s $'\t' || echo "$result" | fmt_json
  else
    echo "$result"
  fi

  if [ "$r" -lt "$ROUNDS" ]; then
    info "Waiting 2s before next round..."
    sleep 2
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_tx_summary

header "Battery Levels After ${ROUNDS} Rounds"
for uav in "${UAVS[@]}"; do
  level=${BAT[$uav]}
  if [ "$level" -le 20 ]; then
    echo -e "  ${uav}: ${RED}${level}%${NC} (CRITICAL)"
  elif [ "$level" -le 50 ]; then
    echo -e "  ${uav}: ${YELLOW}${level}%${NC}"
  else
    echo -e "  ${uav}: ${GREEN}${level}%${NC}"
  fi
done

ok "Telemetry simulation complete."
