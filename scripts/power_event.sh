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

# Detectar estado (1 = AC conectado, 0 = Batería)
STATE=$(cat /sys/class/power_supply/AC/online 2>/dev/null || cat /sys/class/power_supply/ACAD/online 2>/dev/null)

# Función para enviar mensajes a Telegram con reintentos
send_telegram() {
    local MESSAGE="$1"
    local URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    
    until curl -s -X POST "$URL" -d "chat_id=${CHAT_ID}" -d "text=${MESSAGE}" -d "parse_mode=HTML" > /dev/null; do
        sleep 5
    done
}

# ==========================================
# LÓGICA PRINCIPAL
# ==========================================

if [ "$STATE" -eq 0 ]; then
    # --- 1. CORTE DE ELECTRICIDAD ---
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
    else
        START_TIME_HUMAN="Desconocida"
        DURATION_TXT="Tiempo no registrado"
    fi

    MSG="⚡ <b>¡Servicio eléctrico restaurado!</b>%0A%0A📅 <b>Restaurado:</b> ${END_TIME_HUMAN}%0A🕒 <b>Duración del corte:</b> ${DURATION_TXT}"
    send_telegram "$MSG"
fi