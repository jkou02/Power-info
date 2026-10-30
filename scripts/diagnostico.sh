#!/bin/bash
# Diagnóstico del sistema Power-info.
# Uso: sudo ./diagnostico.sh [--enviar]
#   --enviar  Además de verificar, envía un mensaje de prueba a cada destinatario.
#
# Nunca imprime el BOT_TOKEN completo.

set -u

ENV_FILE="/etc/power_monitor.env"
STATE_FILE="/var/lib/power-info/outage_state"
LOCK_FILE="/run/power-info/power_event.lock"
QUEUE_DIR="/var/lib/power-info/queue"
DB_PATH_DEFAULT="/var/db/power_events.db"

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Ejecuta este script con sudo." >&2
    exit 1
fi

ENVIAR=0
[ "${1:-}" = "--enviar" ] && ENVIAR=1

echo "===== Power-info: diagnóstico $(date '+%Y-%m-%d %H:%M:%S') ====="

echo
echo "--- Estado de energía ---"
AC_ESTADO=$(cat /sys/class/power_supply/AC/online 2>/dev/null \
    || cat /sys/class/power_supply/ACAD/online 2>/dev/null \
    || echo "desconocido")
if [ "$AC_ESTADO" = "1" ]; then
    echo "AC: conectado (1)"
elif [ "$AC_ESTADO" = "0" ]; then
    echo "AC: desconectado (0) — el equipo está con batería"
else
    echo "AC: no se pudo leer el estado"
fi

echo
echo "--- Configuración ---"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ No existe $ENV_FILE"
    exit 1
fi
echo "Archivo: $ENV_FILE ($(stat -c '%U:%G %a' "$ENV_FILE"))"

# Cargar de la misma forma que power_event.sh, sin mostrar secretos
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [ -z "${BOT_TOKEN:-}" ]; then
    echo "❌ BOT_TOKEN vacío o no se pudo leer el archivo"
    exit 1
fi
echo "BOT_TOKEN: definido (${#BOT_TOKEN} caracteres, termina en ...${BOT_TOKEN: -4})"

if [ -z "${CHAT_ID:-}" ]; then
    echo "❌ CHAT_ID vacío"
    exit 1
fi
IFS=',' read -ra CHATS <<< "$CHAT_ID"
echo "CHAT_ID: ${#CHATS[@]} destinatario(s)"
DB_PATH="${DB_PATH:-$DB_PATH_DEFAULT}"

echo
echo "--- Bot de Telegram ---"
ME=$(curl -s --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
python3 - "$ME" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("❌ Respuesta no válida de Telegram (¿sin red?)")
    raise SystemExit
if d.get("ok"):
    r = d["result"]
    print(f"✅ Token válido — bot: @{r.get('username')} ({r.get('first_name')})")
else:
    print(f"❌ Token inválido: {d.get('description')} (código {d.get('error_code')})")
PY

echo
echo "--- Destinatarios ---"
for cid in "${CHATS[@]}"; do
    cid=$(echo "$cid" | xargs)
    [ -z "$cid" ] && continue
    CHAT=$(curl -s --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getChat?chat_id=${cid}")
    python3 - "$cid" "$CHAT" <<'PY'
import json, sys
cid, raw = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    print(f"  {cid}: ❌ respuesta no válida")
    raise SystemExit
r = d.get("result") or {}
if d.get("ok"):
    nombre = r.get("first_name") or r.get("title") or "?"
    print(f"  {cid}: ✅ {r.get('type')} — {nombre}")
else:
    print(f"  {cid}: ❌ {d.get('description')} (código {d.get('error_code')})")
PY
done

if [ "$ENVIAR" -eq 1 ]; then
    echo
    echo "--- Envío de prueba ---"
    for cid in "${CHATS[@]}"; do
        cid=$(echo "$cid" | xargs)
        [ -z "$cid" ] && continue
        RESP=$(curl -s --max-time 15 -w '\n%{http_code}' -X POST \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${cid}" \
            --data-urlencode "text=✅ Power-info: prueba de notificaciones ($(date '+%H:%M:%S'))")
        CODE=$(echo "$RESP" | tail -n1)
        BODY=$(echo "$RESP" | sed '$d')
        DESC=$(printf '%s' "$BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("description",""))' 2>/dev/null || echo "respuesta no válida")
        if [ "$CODE" = "200" ] && printf '%s' "$BODY" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
            echo "  ${cid}: ✅ enviado (HTTP 200)"
        else
            echo "  ${cid}: ❌ HTTP ${CODE} — ${DESC}"
        fi
    done
fi

echo
echo "--- Estado interno ---"
if [ ! -e "$STATE_FILE" ]; then
    echo "✅ Sin corte abierto ($STATE_FILE no existe)"
elif [[ "$(head -n1 "$STATE_FILE" 2>/dev/null)" =~ ^[0-9]+$ ]]; then
    EDAD=$(( $(date +%s) - $(stat -c %Y "$STATE_FILE") ))
    echo "⚠️  Corte abierto desde $(sed -n '2p' "$STATE_FILE" 2>/dev/null) (latido hace ${EDAD}s)"
else
    echo "⚠️  $STATE_FILE está vacío o corrupto (no representa un corte); se limpiará en la próxima ejecución"
fi

if [ -e "$LOCK_FILE" ]; then
    echo "Lock: $LOCK_FILE ($(stat -c '%U:%G %a' "$LOCK_FILE"))"
else
    echo "Lock: no existe (se creará en el próximo evento)"
fi

if [ -d "$QUEUE_DIR" ]; then
    PENDIENTES=$(find "$QUEUE_DIR" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l)
    echo "Cola: ${PENDIENTES} notificación(es) pendiente(s) en $QUEUE_DIR"
else
    echo "Cola: no existe todavía ($QUEUE_DIR)"
fi

if systemctl is-enabled power-info-flush.timer >/dev/null 2>&1; then
    echo "Timer de reintentos: $(systemctl is-active power-info-flush.timer) (enabled)"
else
    echo "⚠️  Timer de reintentos no instalado"
fi

if systemctl is-enabled power-info-boot.service >/dev/null 2>&1; then
    echo "Revisión al arranque: $(systemctl is-enabled power-info-boot.service)"
else
    echo "⚠️  Servicio de revisión al arranque no instalado"
fi

if [ -e /tmp/power_outage_time ] || [ -e /var/lock/power_monitor.lock ]; then
    echo "⚠️  Quedan archivos de la versión anterior (lock/estado en /tmp y /var/lock)"
fi

echo
echo "--- Últimos registros en la base de datos ---"
if [ -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" "SELECT id, inicio, fin, duracion_seg FROM cortes ORDER BY id DESC LIMIT 5;" 2>&1
else
    echo "❌ No existe $DB_PATH"
fi

echo
echo "--- Últimos eventos del monitor ---"
journalctl -t power-monitor -n 10 --no-pager 2>&1

echo
echo "===== Fin del diagnóstico ====="
