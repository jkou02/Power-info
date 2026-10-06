#!/bin/bash

set -e

echo "🚀 Instalando Sistema de Monitoreo de Energía..."

# 1. Crear directorios necesarios
sudo mkdir -p /var/db
sudo mkdir -p /etc/udev/rules.d

# 2. Copiar scripts executables a /usr/local/bin
echo "📦 Copiando scripts..."
sudo cp scripts/power_event.sh /usr/local/bin/
sudo cp scripts/generar_grafico.py /usr/local/bin/
sudo chmod +x /usr/local/bin/power_event.sh
sudo chmod +x /usr/local/bin/generar_grafico.py

# 3. Inicializar base de datos con el esquema SQL
echo "🗄️ Inicializando base de datos SQLite..."
if [ -f "schema.sql" ]; then
    sudo apt-get update -qq && sudo apt-get install -y sqlite3 python3-pandas python3-matplotlib python3-dotenv
    sudo sqlite3 /var/db/power_events.db < schema.sql
    sudo chmod 777 /var/db
    sudo chmod 666 /var/db/power_events.db
fi

# 4. Copiar regla de udev
echo "⚡ Configurando regla udev..."
sudo cp rules/99-power-supply.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules

# 5. Crear archivo .env si no existe
if [ ! -f "/etc/power_monitor.env" ]; then
    echo "🔑 Copiando plantilla .env a /etc/power_monitor.env..."
    sudo cp .env.example /etc/power_monitor.env
    sudo chmod 600 /etc/power_monitor.env
    echo "⚠️  IMPORTANTE: Edita /etc/power_monitor.env con tu BOT_TOKEN y CHAT_ID reales."
fi

echo "✅ Instalación completada exitosamente."