#!/bin/bash

# Configurações das câmeras
USER="seu_usuario"
PASS_PATH="sua_senha"
CHANNEL="2"
STREAM="1"

declare -A CAMERAS=(
    [cam1]="00:12:43:A4:92:05"
    [cam2]="00:12:43:A9:BA:FF"
)

# Timeout de rede: 10s sem receber dados = reconecta (valor em microssegundos)
TIMEOUT_US=10000000
if ffmpeg -hide_banner -h demuxer=rtsp 2>&1 | grep -q -- '-stimeout'; then
    TIMEOUT_OPT="-stimeout"   # ffmpeg 4.x e anteriores
else
    TIMEOUT_OPT="-timeout"    # ffmpeg 5.x ou mais novo
fi

# Sleep que pode ser interrompido ao encerrar o script
nap() { sleep "$1" & wait $! 2>/dev/null; }

# Procura o IP pelo MAC (refeito a cada tentativa, caso o IP mude)
find_ip() {
    local iface
    iface=$(ip route | awk '/default/ {print $5; exit}')
    [ -z "$iface" ] && return
    sudo -n arp-scan -x --interface="$iface" --localnet 2>/dev/null \
        | grep -i "$1" | awk '{print $1}' | head -n1
}

run_camera() {
    local NAME="$1" MAC="$2" IP URL
    trap 'kill "$FFPID" 2>/dev/null; exit 0' TERM

    while true; do
        IP=$(find_ip "$MAC")

        if [ -z "$IP" ]; then
            echo "[$(date '+%T')] $NAME: não encontrada na rede. Nova tentativa em 10s..."
            nap 10
            continue
        fi

        echo "[$(date '+%T')] $NAME: conectando em $IP"
        URL="rtsp://admin:suasenha@${IP}:554/user=${USER}_password=${PASS_PATH}_channel=${CHANNEL}_stream=${STREAM}.sdp"

        ffplay -hide_banner -loglevel warning -nostats -autoexit \
            -rtsp_transport tcp "$TIMEOUT_OPT" "$TIMEOUT_US" \
            -window_title "$NAME" "$URL" &
        FFPID=$!
        wait "$FFPID"

        echo "[$(date '+%T')] $NAME: conexão perdida. Reconectando em 5s..."
        nap 5
    done
}

# Ctrl+C encerra tudo
trap 'kill $(jobs -p) 2>/dev/null; exit 0' INT TERM

for NAME in "${!CAMERAS[@]}"; do
    run_camera "$NAME" "${CAMERAS[$NAME]}" &
done

wait