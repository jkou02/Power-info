#!/bin/bash

# ==========================================
# CARGAR CONFIGURACIÓN DESDE .ENV
# ==========================================
ENV_FILE="/etc/power_monitor.env"

if [ -f "$ENV_FILE" ]; then
    # Cargar variables de entorno ignorando líneas vacías y comentarios
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "Error: No se encontró el archivo de configuración $ENV_FILE" >&2
    exit 1
fi

STATE_FILE="/tmp/power_outage_time"

# ==========================================
# SERIALIZACIÓN: Lock global para evitar ejecución concurrente
# El kernel emite 2 uevents por desconexión/reconexión, causando que udev lance
# 2 instancias concurrentes de este script. flock serializa la ejecución.
# ==========================================
LOCK_FILE="/var/lock/power_monitor.lock"
exec 200>"$LOCK_FILE"
if ! flock -w 60 200; then
    logger -t power-monitor "No se pudo adquirir el lock; instancia terminada"
    exit 1
fi

# Detectar estado (1 = AC conectado, 0 = Batería)
STATE=$(cat /sys/class/power_supply/AC/online 2>/dev/null || cat /sys/class/power_supply/ACAD/online 2>/dev/null)

# Función para enviar mensajes a Telegram de forma sincrónica.
# Soporta múltiples destinatarios: CHAT_ID puede contener varios IDs separados por comas.
# El bucle de reintentos se aplica POR destinatario, para que el fallo de uno no afecte a los demás.
send_telegram() {
    local MESSAGE="$1"
    local URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    local RETRIES=5
    
    # Parsear CHAT_ID (soporta formato "id1,id2,id3" o "id1")
    # xargs al cargar el .env quita comillas, pero las comas no son IFS por defecto, así que funciona
    IFS=',' read -ra CHAT_IDS <<< "$CHAT_ID"
    
    for chat_id in "${CHAT_IDS[@]}"; do
        # Trim de espacios e ignorar entradas vacías
        chat_id=$(echo "$chat_id" | xargs)
        [ -z "$chat_id" ] && continue
        
        local COUNT=0
        local SUCCESS=0
        
        while [ $COUNT -lt $RETRIES ]; do
            # --connect-timeout 5 y --max-time 10 evitan que curl se congele
            if curl -s --connect-timeout 5 --max-time 10 -X POST "$URL" -d "chat_id=${chat_id}" -d "text=${MESSAGE}" -d "parse_mode=HTML" > /dev/null; then
                SUCCESS=1
                break
            fi
            COUNT=$((COUNT + 1))
            sleep 3
        done
        
        # Registrar fallo si todos los reintentos fallaron (sin exponer el token)
        if [ $SUCCESS -eq 0 ]; then
            logger -t power-monitor "Error: No se pudo enviar notificación Telegram tras $RETRIES intentos (chat_id=${chat_id})"
        fi
    done
}

# ==========================================
# LÓGICA PRINCIPAL
# ==========================================

if [ "$STATE" -eq 0 ]; then
    # --- 1. CORTE DE ELECTRICIDAD ---
    # Deduplicación: si STATE_FILE ya existe, es el segundo uevent duplicado del kernel
    if [ -f "$STATE_FILE" ]; then
        logger -t power-monitor "Evento de corte duplicado ignorado"
        exit 0
    fi

    START_EPOCH=$(date +%s)
    START_TIME_ISO=$(date +"%Y-%m-%d %H:%M:%S")
    START_TIME_HUMAN=$(date +"%d/%m/%Y a las %I:%M:%S %p")

    echo "$START_EPOCH" > "$STATE_FILE"
    echo "$START_TIME_HUMAN" >> "$STATE_FILE"
    echo "$START_TIME_ISO" >> "$STATE_FILE"

    MSG="⚠️ <b>¡Corte de servicio eléctrico!</b>%0A%0A📅 <b>Inicio:</b> ${START_TIME_HUMAN}%0A🔋 El servidor opera con batería."
    send_telegram "$MSG"

elif [ "$STATE" -eq 1 ]; then
    # --- 2. RESTAURACIÓN DE ELECTRICIDAD ---
    END_EPOCH=$(date +%s)
    END_TIME_ISO=$(date +"%Y-%m-%d %H:%M:%S")
    END_TIME_HUMAN=$(date +"%d/%m/%Y a las %I:%M:%S %p")

    if [ -f "$STATE_FILE" ]; then
        START_EPOCH=$(head -n 1 "$STATE_FILE")
        START_TIME_HUMAN=$(sed -n '2p' "$STATE_FILE")
        START_TIME_ISO=$(sed -n '3p' "$STATE_FILE")

        # Cálculo de la duración
        DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
        HOURS=$((DURATION_SECONDS / 3600))
        MINUTES=$(((DURATION_SECONDS % 3600) / 60))
        SECONDS=$((DURATION_SECONDS % 60))

        DURATION_TXT=""
        [ $HOURS -gt 0 ] && DURATION_TXT="${HOURS}h "
        [ $MINUTES -gt 0 ] && DURATION_TXT="${DURATION_TXT}${MINUTES}m "
        DURATION_TXT="${DURATION_TXT}${SECONDS}s"

        # Inserción en SQLite usando la variable $DB_PATH cargada desde el .env
        sqlite3 "$DB_PATH" "INSERT INTO cortes (inicio, fin, duracion_seg) VALUES ('$START_TIME_ISO', '$END_TIME_ISO', $DURATION_SECONDS);"

        rm -f "$STATE_FILE"

        MSG="⚡ <b>¡Servicio eléctrico restaurado!</b>%0A%0A📅 <b>Restaurado:</b> ${END_TIME_HUMAN}%0A🕒 <b>Duración del corte:</b> ${DURATION_TXT}"
        send_telegram "$MSG"
    else
        # Sin STATE_FILE no hay corte abierto registrado. Esto ocurre cuando el segundo
        # uevent duplicado del kernel dispara esta rama tras haber procesado ya la reconexión.
        logger -t power-monitor "Reconexión sin corte registrado; nada que reportar"
    fi
fi