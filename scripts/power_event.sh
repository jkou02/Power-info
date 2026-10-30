#!/bin/bash
#
# Power-info: registra cortes/reanudaciones de energía y notifica por Telegram.
#
# Uso:
#   power_event.sh                Procesa el evento actual (lo invoca udev como root).
#   power_event.sh --boot-check   Reconcilia el estado al arrancar (servicio de arranque).
#   power_event.sh --flush-queue  Reintenta las notificaciones pendientes (timer).
#   power_event.sh --help         Muestra esta ayuda.
#
# Notas de diseño:
#   - Debe ejecutarse como root: udev lo lanza con systemd-run y los servicios también.
#   - El lock vive en /run/power-info; el estado del corte y la cola en
#     /var/lib/power-info para sobrevivir a reinicios e hibernaciones.
#   - Si no hay red (habitual durante un corte), el mensaje se guarda en una cola
#     persistente y un timer lo reintenta cada minuto hasta entregarlo.

set -u

ENV_FILE="/etc/power_monitor.env"
RUNTIME_DIR="/run/power-info"
DATA_DIR="/var/lib/power-info"
LOCK_FILE="${RUNTIME_DIR}/power_event.lock"
# El estado se guarda en disco para sobrevivir a reinicios y hibernaciones.
STATE_FILE="${DATA_DIR}/outage_state"
QUEUE_DIR="${DATA_DIR}/queue"
LOG_TAG="power-monitor"
DEFAULT_DB_PATH="/var/db/power_events.db"

# Espera máxima por el lock. Si otra instancia sigue enviando, esta se descarta.
LOCK_WAIT=20
# Reintentos rápidos antes de encolar (solo para fallos transitorios).
RETRIES=2
RETRY_DELAY=3
CURL_CONNECT_TIMEOUT=4
CURL_MAX_TIME=8

log() {
    local msg="$1"
    local prio="${2:-user.info}"
    logger -t "$LOG_TAG" -p "$prio" -- "$msg"
}

usage() {
    cat <<EOF
Uso: $0 [OPCIÓN]

  (sin opciones)    Procesa el evento de energía actual.
  --boot-check      Reconcilia el estado tras un reinicio (servicio de arranque).
  --flush-queue     Reintenta las notificaciones pendientes de la cola.
  --help            Muestra esta ayuda.
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ Este script debe ejecutarse como root (udev lo hace automáticamente)." >&2
        echo "   Para probarlo a mano: sudo $0" >&2
        exit 1
    fi
}

load_env() {
    if [ ! -r "$ENV_FILE" ]; then
        log "Error: no se puede leer $ENV_FILE" "user.err"
        echo "❌ No se puede leer $ENV_FILE (¿existe y es legible por root?)" >&2
        exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a

    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
        log "Error: BOT_TOKEN o CHAT_ID no definidos en $ENV_FILE" "user.err"
        echo "❌ BOT_TOKEN o CHAT_ID no definidos en $ENV_FILE" >&2
        exit 1
    fi

    DB_PATH="${DB_PATH:-$DEFAULT_DB_PATH}"
}

prepare_dirs() {
    mkdir -p "$RUNTIME_DIR" "$DATA_DIR" || {
        log "Error: no se pudieron crear $RUNTIME_DIR / $DATA_DIR" "user.err"
        exit 1
    }
    chmod 755 "$RUNTIME_DIR" "$DATA_DIR" 2>/dev/null || true
}

acquire_lock() {
    if ! exec 200>"$LOCK_FILE"; then
        log "Error: no se pudo abrir el lock $LOCK_FILE" "user.err"
        exit 1
    fi

    if ! flock -w "$LOCK_WAIT" 200; then
        log "No se pudo adquirir el lock en ${LOCK_WAIT}s; instancia terminada"
        exit 1
    fi
}

read_ac_state() {
    cat /sys/class/power_supply/AC/online 2>/dev/null \
        || cat /sys/class/power_supply/ACAD/online 2>/dev/null
}

# Devuelve 0 si la red hacia Telegram responde y 1 si no.
network_up() {
    local code
    code=$(curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -o /dev/null -w '%{http_code}' "https://api.telegram.org" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ]
}

# Envía un mensaje a un chat.
# Retorno: 0 = entregado, 1 = fallo transitorio (reintentar/encolar),
#          2 = fallo permanente (token inválido, chat inexistente, bot bloqueado...).
# Deja el detalle en SEND_CODE y SEND_DESC.
send_one() {
    local chat_id="$1"
    local text="$2"
    local raw code body

    raw=$(curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -w $'\n%{http_code}' -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" 2>&1)

    code=${raw##*$'\n'}
    body=${raw%$'\n'*}
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"

    SEND_CODE="$code"
    SEND_DESC=$(printf '%s' "$body" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p' | head -n1)

    if [ "$code" = "200" ] && printf '%s' "$body" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
        return 0
    fi

    case "$code" in
        000|408|429|5??) return 1 ;;
        *) return 2 ;;
    esac
}

queue_message() {
    local chat_id="$1"
    local text="$2"
    local ts rand safe_id file

    if ! mkdir -p "$QUEUE_DIR"; then
        log "Error: no se pudo crear la cola $QUEUE_DIR" "user.err"
        return 1
    fi
    chmod 700 "$QUEUE_DIR" 2>/dev/null || true

    ts=$(date +%s)
    rand=$RANDOM
    safe_id=$(printf '%s' "$chat_id" | tr -cd '0-9-')
    file="${QUEUE_DIR}/${ts}__${rand}__${safe_id}.msg"

    if printf '%s' "$text" > "$file"; then
        chmod 600 "$file" 2>/dev/null || true
        return 0
    fi

    log "Error: no se pudo escribir en la cola ($file)" "user.err"
    return 1
}

# Envía a todos los destinatarios. Lo que no se entregue queda encolado.
send_telegram() {
    local message="$1"
    local chat_id rc
    local -a chat_ids

    IFS=',' read -ra chat_ids <<< "${CHAT_ID}"

    if ! network_up; then
        log "Sin conectividad hacia Telegram; las notificaciones se encolan"
        for chat_id in "${chat_ids[@]}"; do
            chat_id=$(echo "$chat_id" | xargs)
            [ -z "$chat_id" ] && continue
            if ! [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
                log "CHAT_ID inválido ('$chat_id'); se ignora" "user.warning"
                continue
            fi
            queue_message "$chat_id" "$message"
        done
        return 0
    fi

    for chat_id in "${chat_ids[@]}"; do
        chat_id=$(echo "$chat_id" | xargs)
        [ -z "$chat_id" ] && continue
        if ! [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
            log "CHAT_ID inválido ('$chat_id'); se ignora" "user.warning"
            continue
        fi

        local attempt=1
        while [ "$attempt" -le "$RETRIES" ]; do
            send_one "$chat_id" "$message"
            rc=$?
            [ "$rc" -eq 0 ] && break
            [ "$rc" -eq 2 ] && break
            if [ "$attempt" -lt "$RETRIES" ]; then
                sleep "$RETRY_DELAY"
            fi
            attempt=$((attempt + 1))
        done

        case "$rc" in
            0)
                ;;
            2)
                log "Error permanente de Telegram (chat_id=${chat_id}, HTTP ${SEND_CODE}): ${SEND_DESC:-sin descripción}"
                ;;
            *)
                log "Fallo transitorio de Telegram (chat_id=${chat_id}, HTTP ${SEND_CODE}); mensaje encolado"
                queue_message "$chat_id" "$message"
                ;;
        esac
    done
}

flush_queue() {
    local file chat_id message rc count=0
    local sent=0 kept=0 discarded=0
    local -a pending

    mkdir -p "$QUEUE_DIR" 2>/dev/null || return 1
    chmod 700 "$QUEUE_DIR" 2>/dev/null || true

    # Latido: mientras haya un corte abierto se actualiza su mtime. Si el equipo
    # se apaga o hiberna, ese sello es la última hora en que estuvo encendido.
    if is_outage_open; then
        touch "$STATE_FILE" 2>/dev/null || true
    else
        discard_invalid_state || true
    fi

    # Descartar entradas demasiado antiguas para no acumular basura.
    find "$QUEUE_DIR" -maxdepth 1 -name '*.msg' -mtime +7 -delete 2>/dev/null || true

    shopt -s nullglob
    pending=("$QUEUE_DIR"/*.msg)
    # Sin pendientes no hace falta comprobar la red ni despertar al equipo.
    [ ${#pending[@]} -eq 0 ] && return 0

    if ! network_up; then
        return 0
    fi

    for file in "${pending[@]}"; do
        [ "$count" -ge 50 ] && break
        count=$((count + 1))

        chat_id=${file##*__}
        chat_id=${chat_id%.msg}
        message=$(cat "$file" 2>/dev/null) || continue
        [ -z "$message" ] && { rm -f "$file"; continue; }

        send_one "$chat_id" "$message"
        rc=$?

        case "$rc" in
            0)
                rm -f "$file"
                sent=$((sent + 1))
                log "Notificación pendiente entregada (chat_id=${chat_id})"
                ;;
            2)
                rm -f "$file"
                discarded=$((discarded + 1))
                log "Notificación pendiente descartada (chat_id=${chat_id}, HTTP ${SEND_CODE}): ${SEND_DESC:-sin descripción}"
                ;;
            *)
                kept=$((kept + 1))
                ;;
        esac
    done

    if [ "$sent" -gt 0 ] || [ "$discarded" -gt 0 ]; then
        log "Cola procesada: ${sent} entregadas, ${discarded} descartadas, ${kept} pendientes"
    fi
}

is_outage_open() {
    local previous

    [ -f "$STATE_FILE" ] || return 1
    previous=$(head -n1 "$STATE_FILE" 2>/dev/null)
    [[ "$previous" =~ ^[0-9]+$ ]] || return 1
    return 0
}

# Guarda el estado del corte de forma atómica: se escribe en un temporal y se
# renombra. Así una interrupción a mitad de escritura nunca deja un estado
# vacío o truncado que luego parezca un corte abierto.
write_state() {
    local inicio_epoch="$1" inicio_human="$2" inicio_iso="$3" tmp

    tmp=$(mktemp "${DATA_DIR}/.outage_state.XXXXXX" 2>/dev/null) || {
        log "Error: no se pudo crear el temporal del estado" "user.err"
        return 1
    }

    if ! printf '%s\n%s\n%s\n' "$inicio_epoch" "$inicio_human" "$inicio_iso" > "$tmp"; then
        rm -f "$tmp"
        log "Error: no se pudo escribir el estado del corte" "user.err"
        return 1
    fi

    chmod 600 "$tmp" 2>/dev/null || true

    if ! mv -f "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        log "Error: no se pudo guardar el estado del corte" "user.err"
        return 1
    fi

    return 0
}

# Elimina un state vacío o corrupto (p. ej. de una ejecución interrumpida).
# Devuelve 0 solo si realmente lo eliminó.
discard_invalid_state() {
    local previous

    [ -e "$STATE_FILE" ] || return 1
    previous=$(head -n1 "$STATE_FILE" 2>/dev/null)
    [[ "$previous" =~ ^[0-9]+$ ]] && return 1

    log "Estado de corte vacío o corrupto; se descarta" "user.warning"
    rm -f "$STATE_FILE"
    return 0
}

formatear_duracion() {
    local total="$1"
    local horas=$((total / 3600))
    local minutos=$(((total % 3600) / 60))
    local segundos=$((total % 60))
    local salida=""

    [ "$horas" -gt 0 ] && salida="${horas}h "
    [ "$minutos" -gt 0 ] && salida="${salida}${minutos}m "
    printf '%s' "${salida}${segundos}s"
}

registrar_corte() {
    local inicio="$1" fin="$2" duracion="$3"

    if command -v sqlite3 >/dev/null 2>&1; then
        if ! sqlite3 "$DB_PATH" "INSERT INTO cortes (inicio, fin, duracion_seg) VALUES ('$inicio', '$fin', $duracion);" 2>/dev/null; then
            log "Error: no se pudo registrar el corte en $DB_PATH" "user.err"
            return 1
        fi
    else
        log "Error: sqlite3 no está instalado; no se registró el corte" "user.err"
        return 1
    fi

    return 0
}

# Cierra el corte abierto con la hora indicada y notifica.
# modo=normal: restauración detectada en vivo.
# modo=boot:   cierre estimado tras un reinicio/hibernación.
cerrar_corte() {
    local end_epoch="$1" modo="${2:-normal}"
    local start_epoch start_human start_iso end_iso end_human duration message

    [ -f "$STATE_FILE" ] || return 1

    start_epoch=$(head -n1 "$STATE_FILE" 2>/dev/null)
    start_human=$(sed -n '2p' "$STATE_FILE" 2>/dev/null)
    start_iso=$(sed -n '3p' "$STATE_FILE" 2>/dev/null)

    if ! [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
        log "Estado de corte corrupto; se descarta" "user.warning"
        rm -f "$STATE_FILE"
        return 1
    fi

    [ "$end_epoch" -lt "$start_epoch" ] && end_epoch="$start_epoch"
    duration=$((end_epoch - start_epoch))

    end_iso=$(date -d "@$end_epoch" +"%Y-%m-%d %H:%M:%S")
    end_human=$(date -d "@$end_epoch" +"%d/%m/%Y a las %I:%M:%S %p")

    registrar_corte "$start_iso" "$end_iso" "$duration"
    rm -f "$STATE_FILE"

    if [ "$modo" = "boot" ]; then
        message=$(printf '⚡ <b>Servicio eléctrico restaurado</b>\n\n📅 <b>Fin estimado:</b> %s\n🕒 <b>Duración estimada:</b> %s\nℹ️ El equipo estuvo apagado o suspendido durante el corte.' "$end_human" "$(formatear_duracion "$duration")")
    else
        message=$(printf '⚡ <b>¡Servicio eléctrico restaurado!</b>\n\n📅 <b>Restaurado:</b> %s\n🕒 <b>Duración del corte:</b> %s' "$end_human" "$(formatear_duracion "$duration")")
    fi

    send_telegram "$message"
}

handle_outage() {
    local now start_iso start_human message

    now=$(date +%s)

    if is_outage_open; then
        # Segundo uevent del mismo corte o corte que sigue abierto tras un
        # reinicio: se conserva el inicio original y no se duplica el aviso.
        touch "$STATE_FILE" 2>/dev/null || true
        log "Corte ya en curso; se mantiene el estado registrado"
        exit 0
    fi

    if [ -f "$STATE_FILE" ] && ! is_outage_open; then
        discard_invalid_state || true
    fi

    start_iso=$(date +"%Y-%m-%d %H:%M:%S")
    start_human=$(date +"%d/%m/%Y a las %I:%M:%S %p")

    write_state "$now" "$start_human" "$start_iso"

    message=$(printf '⚠️ <b>¡Corte de servicio eléctrico!</b>\n\n📅 <b>Inicio:</b> %s\n🔋 El servidor opera con batería.' "$start_human")
    send_telegram "$message"
}

handle_restoration() {
    if [ ! -f "$STATE_FILE" ]; then
        log "Reconexión sin corte registrado; nada que reportar"
        exit 0
    fi

    cerrar_corte "$(date +%s)" normal
}

# Se ejecuta al arrancar el sistema. Reconcilia el estado que sobrevivió en
# disco: si el equipo arrancó con batería inicia un corte; si arrancó con
# corriente y había un corte abierto, lo cierra usando el último latido.
handle_boot_check() {
    local state now start_human start_iso last_seen message

    # Un state vacío/corrupto (p. ej. de una ejecución interrumpida) no
    # representa un corte: se limpia antes de conciliar.
    discard_invalid_state || true

    state=$(read_ac_state)

    case "$state" in
        0)
            if is_outage_open; then
                touch "$STATE_FILE" 2>/dev/null || true
                log "Arranque con batería: el corte ya estaba registrado; se mantiene"
            else
                now=$(date +%s)
                start_iso=$(date +"%Y-%m-%d %H:%M:%S")
                start_human=$(date +"%d/%m/%Y a las %I:%M:%S %p")

                write_state "$now" "$start_human" "$start_iso"

                message=$(printf '⚠️ <b>El equipo arrancó con batería</b>\n\n📅 <b>Detectado:</b> %s\n🔋 Sin conexión a la red eléctrica.\nℹ️ El inicio real del corte pudo ser anterior al arranque.' "$start_human")
                send_telegram "$message"
            fi
            ;;
        1)
            if is_outage_open; then
                last_seen=$(stat -c %Y "$STATE_FILE" 2>/dev/null)
                [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=$(date +%s)
                log "Arranque con corriente y corte pendiente; se cierra con el último latido ($(date -d "@$last_seen" +"%Y-%m-%d %H:%M:%S"))"
                cerrar_corte "$last_seen" boot
            else
                log "Arranque con corriente; sin corte pendiente"
            fi
            ;;
        *)
            log "No se pudo leer el estado de energía al arrancar" "user.err"
            exit 1
            ;;
    esac

    flush_queue
}

main() {
    local state

    require_root
    load_env
    prepare_dirs
    acquire_lock

    state=$(read_ac_state)

    case "$state" in
        0) handle_outage ;;
        1) handle_restoration ;;
        *)
            log "No se pudo leer el estado de energía (¿existe /sys/class/power_supply/AC*?)" "user.err"
            exit 1
            ;;
    esac
}

case "${1:-}" in
    "")
        main
        ;;
    --boot-check)
        require_root
        load_env
        prepare_dirs
        acquire_lock
        handle_boot_check
        ;;
    --flush-queue)
        require_root
        load_env
        prepare_dirs
        flush_queue
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Opción desconocida: $1" >&2
        usage >&2
        exit 1
        ;;
esac
