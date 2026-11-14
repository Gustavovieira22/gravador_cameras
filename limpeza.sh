#!/usr/bin/env bash
# Apaga pastas de dia (YYYY-MM-DD) com mais de DAYS dias em BASE_DIR/camX/.
# Uso:
#   ./limpar_videos.sh              # apaga de verdade
#   ./limpar_videos.sh --dry-run    # so mostra o que seria apagado
#
# Variaveis opcionais (ambiente): BASE_DIR, DAYS
set -euo pipefail

BASE_DIR="${BASE_DIR:-/home/calango/DVR/videos}"
DAYS="${DAYS:-15}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { echo "[$(date '+%F %T')] $*"; }

# Protecoes basicas
if [[ -z "$BASE_DIR" || "$BASE_DIR" == "/" ]]; then
  log "BASE_DIR invalido: '$BASE_DIR'" >&2
  exit 1
fi
if [[ ! -d "$BASE_DIR" ]]; then
  log "Pasta '$BASE_DIR' nao existe." >&2
  exit 1
fi
if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( DAYS < 1 )); then
  log "DAYS invalido: '$DAYS'" >&2
  exit 1
fi

# Data de corte: pastas com data anterior a esta sao apagadas.
# Ex.: hoje 2026-11-13 e DAYS=15 -> corte 2026-10-29 (a pasta de 10-29 fica, a de 10-28 sai)
CUTOFF="$(date -d "-${DAYS} days" +%F)"

log "Varrendo '$BASE_DIR' (apagando pastas anteriores a $CUTOFF)$( ((DRY_RUN)) && echo ' [DRY-RUN]' )"

REMOVED=0
for cam_dir in "$BASE_DIR"/*/; do
  [[ -d "$cam_dir" ]] || continue

  for day_dir in "$cam_dir"*/; do
    [[ -d "$day_dir" ]] || continue

    day_dir="${day_dir%/}"
    name="$(basename "$day_dir")"

    # So mexe em pastas com nome no formato YYYY-MM-DD
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue

    # Comparacao de texto funciona porque o formato e YYYY-MM-DD
    if [[ "$name" < "$CUTOFF" ]]; then
      if (( DRY_RUN )); then
        log "[dry-run] apagaria: $day_dir"
      else
        log "Apagando: $day_dir"
        rm -rf -- "$day_dir"
      fi
      REMOVED=$((REMOVED + 1))
    fi
  done
done

log "Concluido. Pastas $( ((DRY_RUN)) && echo 'que seriam apagadas' || echo 'apagadas' ): $REMOVED"