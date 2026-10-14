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

REPO=/home/serverjkou/Power-info

echo "== Copiando scripts =="
cp "$REPO/scripts/power_event.sh" /usr/local/bin/
cp "$REPO/scripts/generar_grafico.py" /usr/local/bin/
chmod +x /usr/local/bin/power_event.sh /usr/local/bin/generar_grafico.py

echo "== Validando sintaxis =="
bash -n /usr/local/bin/power_event.sh
python3 -m py_compile /usr/local/bin/generar_grafico.py

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
        code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${cid}" -d "text=✅ Power-info: prueba de notificaciones múltiples")
        echo "  chat_id ${cid} -> HTTP ${code} (200 = recibido)"
    done
fi
