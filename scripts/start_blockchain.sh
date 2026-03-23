#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# start_blockchain.sh
# Ejecuta secuencialmente:
#   00-resolve-hosts.sh
#   01-generate-crypto.sh
#   02-generate-channel-artifacts.sh
#   03-distribute.sh
#   04-start-network.sh
#
# Muestra progreso general y salida en tiempo real.
# También guarda logs por paso.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"

STEPS=(
  "00-resolve-hosts.sh"
  "01-generate-crypto.sh"
  "02-generate-channel-artifacts.sh"
  "03-distribute.sh"
  "04-start-network.sh"
)

TOTAL_STEPS=${#STEPS[@]}
CURRENT_STEP=0

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

separator() {
  printf '%*s\n' "${COLUMNS:-100}" '' | tr ' ' '='
}

progress_bar() {
  local current="$1"
  local total="$2"
  local width=40
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))

  printf "["
  printf "%0.s#" $(seq 1 "$filled")
  printf "%0.s-" $(seq 1 "$empty")
  printf "] %d/%d" "$current" "$total"
}

log() {
  echo "[$(timestamp)] $*"
}

abort() {
  local exit_code=$?
  local line_no=$1
  echo
  separator
  log "ERROR en la línea ${line_no}. Ejecución abortada. Código de salida: ${exit_code}"
  separator
  exit "${exit_code}"
}
trap 'abort $LINENO' ERR

run_step() {
  local script_name="$1"
  local step_index="$2"
  local log_file="${LOG_DIR}/$(printf "%02d" "$step_index")-${script_name%.sh}.log"
  local start_ts end_ts elapsed

  CURRENT_STEP=$((CURRENT_STEP + 1))

  if [[ ! -f "${SCRIPT_DIR}/${script_name}" ]]; then
    separator
    log "ERROR: no se encontró ${SCRIPT_DIR}/${script_name}"
    separator
    exit 1
  fi

  if [[ ! -x "${SCRIPT_DIR}/${script_name}" ]]; then
    chmod +x "${SCRIPT_DIR}/${script_name}"
  fi

  echo
  separator
  log "Progreso general: $(progress_bar "${CURRENT_STEP}" "${TOTAL_STEPS}")"
  log "Ejecutando paso ${CURRENT_STEP}/${TOTAL_STEPS}: ${script_name}"
  log "Log del paso: ${log_file}"
  separator

  start_ts=$(date +%s)

  (
    echo "[$(timestamp)] INICIO ${script_name}"
    bash "${SCRIPT_DIR}/${script_name}"
    echo "[$(timestamp)] FIN ${script_name}"
  ) 2>&1 | tee "${log_file}"

  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))

  echo
  log "Paso completado: ${script_name} (${elapsed}s)"
}

main() {
  separator
  log "Inicio del despliegue blockchain"
  log "Directorio de scripts: ${SCRIPT_DIR}"
  log "Logs: ${LOG_DIR}"
  log "Total de pasos: ${TOTAL_STEPS}"
  separator

  local i=0
  for step in "${STEPS[@]}"; do
    run_step "${step}" "$i"
    i=$((i + 1))
  done

  echo
  separator
  log "Progreso general: $(progress_bar "${TOTAL_STEPS}" "${TOTAL_STEPS}")"
  log "Todos los pasos se completaron correctamente"
  separator
}

main "$@"