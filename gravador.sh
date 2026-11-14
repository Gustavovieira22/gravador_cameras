#!/usr/bin/env bash
set -euo pipefail

CAM="${1:-}"
if [[ -z "$CAM" ]]; then
  echo "Uso: $0 cam1|cam2|..."
  exit 2
fi

source /home/calango/DVR/cameras.conf

: "${BASE_DIR:?}"
: "${SEG_TIME:?}"
: "${CAM_IP[$CAM]:?}"
: "${CAM_USER[$CAM]:?}"
: "${CAM_PASS[$CAM]:?}"
: "${CAM_CHANNEL[$CAM]:?}"
: "${CAM_STREAM[$CAM]:?}"

# Timeout de I/O do RTSP (10s, em microssegundos).
# ffmpeg 4.x usa -stimeout; ffmpeg 5.x+ usa -timeout.
RTSP_TIMEOUT_US=10000000
if ffmpeg -hide_banner -h demuxer=rtsp 2>&1 | grep -q -- '-stimeout'; then
  RTSP_TIMEOUT_OPT="-stimeout"
else
  RTSP_TIMEOUT_OPT="-timeout"
fi

FFPID=""

# Sleep que pode ser interrompido pelo trap
nap() {
  sleep "$1" &
  wait $! 2>/dev/null || true
}

# Ao receber Ctrl+C / systemctl stop, encerra o ffmpeg direito e sai
cleanup() {
  echo "[$(date '+%F %T')] Encerrando gravacao da camera '$CAM'..."
  if [[ -n "$FFPID" ]] && kill -0 "$FFPID" 2>/dev/null; then
    kill -TERM "$FFPID" 2>/dev/null || true
    wait "$FFPID" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup INT TERM

is_mac_address() {
  local v="${1,,}"
  [[ "$v" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]
}

find_camera_ip_by_mac() {
  local mac="${1,,}"
  local ip=""
  local scan_output=""

  if command -v arp-scan &>/dev/null; then
    if scan_output="$(arp-scan --localnet --plain --quiet 2>/dev/null)"; then
      ip="$(awk -v mac="$mac" 'tolower($2) == mac { print $1; exit }' <<< "$scan_output")"
    fi
  fi

  if [[ -z "$ip" ]]; then
    ip="$(ip neigh 2>/dev/null | awk -v mac="$mac" 'tolower($5) == mac { print $1; exit }')"
  fi

  printf '%s' "$ip"
}

resolve_camera_host() {
  local value="$1"

  if is_mac_address "$value"; then
    find_camera_ip_by_mac "$value"
  else
    printf '%s' "$value"
  fi
}

ADDR="${CAM_IP[$CAM]}"
USER="${CAM_USER[$CAM]}"
PASS="${CAM_PASS[$CAM]}"
CH="${CAM_CHANNEL[$CAM]}"
ST="${CAM_STREAM[$CAM]}"

while true; do
  HOST="$(resolve_camera_host "$ADDR" || true)"

  if [[ -z "$HOST" ]]; then
    echo "Nao encontrei IP para a camera '$CAM' a partir de '$ADDR'. Tentando novamente em 10s..."
    nap 10
    continue
  fi

  # Pasta somente do dia atual
  TODAY="$(date +%F)"
  OUT_DIR="${BASE_DIR}/${CAM}/${TODAY}"
  mkdir -p "$OUT_DIR"

  # Segundos restantes ate a meia-noite
  NOW="$(date +%s)"
  MIDNIGHT="$(date -d 'tomorrow 00:00:00' +%s)"
  REMAINING=$(( MIDNIGHT - NOW ))

  # Se faltar menos de 2s, espera virar o dia e recomeca
  if (( REMAINING < 2 )); then
    nap "$REMAINING"
    continue
  fi

  URL="rtsp://${HOST}/user=${USER}&password=${PASS}&channel=${CH}&stream=${ST}.sdb"

  echo "[$(date '+%F %T')] Conectando camera '$CAM' em '$HOST' (gravando em $OUT_DIR por ${REMAINING}s)"

  # timeout envia SIGINT na meia-noite, e o ffmpeg fecha o ultimo arquivo corretamente.
  # Roda em background + wait para o trap conseguir agir imediatamente.
  timeout -s INT -k 10 "$REMAINING" \
    ffmpeg -nostdin -hide_banner -loglevel info \
      -rtsp_transport tcp \
      "$RTSP_TIMEOUT_OPT" "$RTSP_TIMEOUT_US" \
      -i "$URL" \
      -map 0 \
      -c:v copy -c:a aac -b:a 128k -ar 48000 \
      -f segment \
      -segment_time "$SEG_TIME" \
      -segment_atclocktime 1 \
      -reset_timestamps 1 \
      -strftime 1 \
      "${OUT_DIR}/${CAM}_%Y-%m-%d_%H-%M-%S.mkv" &
  FFPID=$!
  wait "$FFPID" || true
  FFPID=""

  # Se ainda for o mesmo dia, foi queda da camera: espera e reconecta.
  # Se virou o dia, reinicia imediatamente com a nova pasta.
  if [[ "$(date +%F)" == "$TODAY" ]]; then
    echo "[$(date '+%F %T')] ffmpeg caiu para '$CAM'. Tentando novamente em 5s..."
    nap 5
  else
    echo "[$(date '+%F %T')] Novo dia, iniciando nova gravacao para '$CAM'."
  fi
done