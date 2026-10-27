#!/bin/bash
# Despliega Power-info multi-destinatario en este servidor. Ejecutar con sudo.
# Uso: sudo bash deploy_multirecipient.sh "id1,id2,id3" [--probar]
set -e

IDS="$1"
if [ -z "$IDS" ]; then
    echo "Uso: sudo bash $0 \"id1,id2,id3\" [--probar]"
    exit 1
fi
# Validar formato: solo números (positivos/negativos) separados por comas, sin espacios
if ! [[ "$IDS" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]]; then
    echo "Formato inválido. Ejemplo: 12345,67890,11111 (sin espacios)"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Ejecuta este script con sudo." >&2
    exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Copiando scripts =="
cp "$REPO/scripts/power_event.sh" /usr/local/bin/
cp "$REPO/scripts/generar_grafico.py" /usr/local/bin/
chmod +x /usr/local/bin/power_event.sh /usr/local/bin/generar_grafico.py

echo "== Validando sintaxis =="
bash -n /usr/local/bin/power_event.sh
python3 -m py_compile /usr/local/bin/generar_grafico.py

echo "== Preparando cola y timer de reintentos =="
mkdir -p /var/lib/power-info/queue /run/power-info
chmod 700 /var/lib/power-info/queue
chmod 755 /run/power-info
rm -f /var/lock/power_monitor.lock /tmp/power_outage_time
cp "$REPO/systemd/power-info-flush.service" /etc/systemd/system/
cp "$REPO/systemd/power-info-flush.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now power-info-flush.timer

echo "== Actualizando /etc/power_monitor.env (con respaldo) =="
BAK="/etc/power_monitor.env.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/power_monitor.env "$BAK"
sed -i "s/^CHAT_ID=.*/CHAT_ID=\"${IDS}\"/" /etc/power_monitor.env
# Mostrar solo líneas no sensibles (nunca BOT_TOKEN)
grep -E '^(CHAT_ID|DB_PATH)=' /etc/power_monitor.env

echo "✅ Despliegue listo (respaldo: $BAK)"

if [ "$2" = "--probar" ]; then
    echo "== Prueba de envío a cada destinatario =="
    . /etc/power_monitor.env
    IFS=',' read -ra ARR <<< "$CHAT_ID"
    for cid in "${ARR[@]}"; do
        cid=$(echo "$cid" | xargs)
        RESP=$(curl -s --max-time 15 -w $'\n%{http_code}' -X POST \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${cid}" \
            --data-urlencode "text=✅ Power-info: prueba de notificaciones múltiples")
        CODE=${RESP##*$'\n'}
        BODY=${RESP%$'\n'*}
        DESC=$(printf '%s' "$BODY" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p' | head -n1)
        if [ "$CODE" = "200" ] && printf '%s' "$BODY" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
            echo "  chat_id ${cid} -> HTTP 200 (recibido)"
        else
            echo "  chat_id ${cid} -> HTTP ${CODE} ${DESC:+— $DESC}"
        fi
    done
fi
