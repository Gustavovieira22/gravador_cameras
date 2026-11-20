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

# ---------------------------------------------------------------------------
# Privilégios mínimos
#
# Só o arp-scan precisa de root (ele abre sockets raw). A senha do sudo é
# pedida UMA única vez, no início do script, e o cache de credenciais é
# renovado em background enquanto o script estiver rodando. O ffplay, os
# laços, os traps e todo o resto continuam rodando como usuário comum.
#
# Alternativas sem senha (opcional, uma vez só):
#   sudo setcap cap_net_raw+p "$(command -v arp-scan || echo /usr/sbin/arp-scan)"
#   ou uma regra NOPASSWD no sudoers apenas para o arp-scan.
# ---------------------------------------------------------------------------

# arp-scan pode estar fora do PATH (Debian: /usr/sbin, Arch: /usr/bin, etc.)
find_arp_scan() {
    local p
    if p=$(command -v arp-scan 2>/dev/null) && [ -x "$p" ]; then
        printf '%s' "$p"
        return 0
    fi
    for p in /usr/sbin/arp-scan /usr/bin/arp-scan /sbin/arp-scan \
             /usr/local/sbin/arp-scan /usr/local/bin/arp-scan; do
        if [ -x "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

ARP_SCAN_BIN="$(find_arp_scan || true)"
SUDO_OK=0               # 1 = rodar o arp-scan através do sudo
SUDO_KEEPALIVE_PID=""   # PID do processo que renova o cache do sudo

# Existe um terminal para digitar a senha?
have_tty() { { : </dev/tty; } 2>/dev/null; }

# Pede a senha do sudo (só para o arp-scan) e mantém o cache válido
init_privileges() {
    # Sem arp-scan instalado: nada a fazer, o ip neigh resolve
    [ -x "$ARP_SCAN_BIN" ] || { ARP_SCAN_BIN=""; return 0; }

    # Já somos root: roda direto, sem sudo nem senha
    if [ "$EUID" -eq 0 ]; then
        SUDO_OK=0
        return 0
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        echo "[$(date '+%T')] aviso: arp-scan precisa de root e o sudo não está instalado." >&2
        echo "[$(date '+%T')] aviso: usando a tabela ARP do kernel (ip neigh) como alternativa." >&2
        ARP_SCAN_BIN=""
        return 0
    fi

    if sudo -n true 2>/dev/null; then
        SUDO_OK=1                       # senha já em cache / NOPASSWD
    else
        if have_tty; then
            echo "==> O arp-scan precisa de root. A senha do sudo é usada apenas por ele;" >&2
            echo "    o restante do script continua rodando como o seu usuário." >&2
        fi
        if have_tty && sudo -v; then
            SUDO_OK=1                   # pediu a senha uma única vez
        else
            echo "[$(date '+%T')] aviso: sem permissão para o arp-scan." >&2
            echo "[$(date '+%T')] aviso: usando a tabela ARP do kernel (ip neigh) como alternativa." >&2
            ARP_SCAN_BIN=""
            return 0
        fi
    fi

    # Renova a credencial do sudo a cada 60s para nunca pedir a senha de novo.
    # (sem redirecionar stdout/stderr, para o sudo localizar o terminal)
    (
        while sleep 60; do
            sudo -n -v 2>/dev/null || exit 0
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

# Varredura da rede com o privilégio já resolvido (só este comando usa root)
run_arp_scan() {
    local iface="$1" out=""
    if [ "$SUDO_OK" -eq 1 ]; then
        out=$(sudo -n "$ARP_SCAN_BIN" --plain --quiet \
                  --interface="$iface" --localnet 2>/dev/null)
        # Credencial do sudo expirou (só acontece se o keepalive morrer)
        if [ -z "$out" ] && ! sudo -n -v 2>/dev/null; then
            echo "[$(date '+%T')] aviso: a credencial do sudo expirou; reinicie o script para voltar a usar o arp-scan." >&2
        fi
    else
        out=$("$ARP_SCAN_BIN" --plain --quiet \
                  --interface="$iface" --localnet 2>/dev/null)
    fi
    printf '%s\n' "$out"
}

# Cache da varredura: as câmeras compartilham o mesmo resultado por SCAN_TTL
# segundos, para não rodar arp-scan uma vez para cada câmera ao mesmo tempo
SCAN_TTL=30
SCAN_CACHE="${TMPDIR:-/tmp}/camera.sh.arp.${UID}"

scan_network() {
    local iface="$1" now ts out
    (
        exec 9>"${SCAN_CACHE}.lock"
        command -v flock >/dev/null 2>&1 && flock -w 20 9

        now=$(date +%s)
        if [ -s "$SCAN_CACHE" ]; then
            read -r ts < "$SCAN_CACHE"
            if [[ "$ts" =~ ^[0-9]+$ ]] && [ "$((now - ts))" -lt "$SCAN_TTL" ]; then
                tail -n +2 "$SCAN_CACHE"
                exit 0
            fi
        fi

        out=$(run_arp_scan "$iface")
        if [ -n "$out" ]; then
            { printf '%s\n' "$now"; printf '%s\n' "$out"; } > "$SCAN_CACHE"
        fi
        printf '%s\n' "$out"
    )
}

# Procura o IP pelo MAC (refeito a cada tentativa, caso o IP mude)
find_ip() {
    local mac="${1,,}" iface ip
    iface=$(ip route | awk '/default/ {print $5; exit}')
    [ -z "$iface" ] && return

    # 1) arp-scan (precisa de root, já resolvido em init_privileges)
    if [ -n "$ARP_SCAN_BIN" ] && [ -x "$ARP_SCAN_BIN" ]; then
        ip=$(scan_network "$iface" | awk -v mac="$mac" 'tolower($2) == mac {print $1; exit}')
        if [ -n "$ip" ]; then
            printf '%s\n' "$ip"
            return
        fi
    fi

    # 2) Tabela ARP do kernel (sem privilégio nenhum)
    ip neigh 2>/dev/null | awk -v mac="$mac" \
        'tolower($5) == mac && $6 !~ /FAILED|INCOMPLETE/ {print $1; exit}'
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

# Ctrl+C encerra tudo (inclusive o keepalive do sudo)
shutdown() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f "${SCAN_CACHE:-/nonexistent}" "${SCAN_CACHE:-/nonexistent}.lock" 2>/dev/null
    exit 0
}
trap shutdown INT TERM

# Pede a senha do sudo uma única vez, apenas para viabilizar o arp-scan
init_privileges

for NAME in "${!CAMERAS[@]}"; do
    run_camera "$NAME" "${CAMERAS[$NAME]}" &
done

wait