#!/bin/bash
# uninstall.sh
# Contra-procedimiento de install.sh
# Autor: jkou
# Descripción: Desinstala el sistema de monitoreo de energía
# Uso: sudo ./uninstall.sh [--purge-config] [--purge-data] [--all] [-h|--help]

set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Paths a desinstalar
BIN_POWER_EVENT="/usr/local/bin/power_event.sh"
BIN_GRAFICO_PY="/usr/local/bin/generar_grafico.py"
BIN_GRAFICOS_PY="/usr/local/bin/generar_graficos.py"
RULE_FILE="/etc/udev/rules.d/99-power-supply.rules"
ENV_FILE="/etc/power_monitor.env"
DB_FILE="/var/db/power_events.db"

# Flags
PURGE_CONFIG=false
PURGE_DATA=false

show_help() {
    echo "🛠️  Uso: sudo ./uninstall.sh [OPCIONES]"
    echo ""
    echo "Desinstala el sistema de monitoreo de energía."
    echo ""
    echo "⚙️  Modo seguro (por defecto):"
    echo "   Elimina solo los binarios y la regla udev."
    echo "   Conserva la configuración (/etc/power_monitor.env) y la base de datos (/var/db/power_events.db)."
    echo ""
    echo "🗑️  Opciones de purga:"
    echo "   --purge-config    Elimina también $ENV_FILE (contiene el token de Telegram)"
    echo "   --purge-data      Elimina también $DB_FILE (datos históricos de cortes)"
    echo "   --all             Equivale a --purge-config + --purge-data"
    echo ""
    echo "📋 Otros:"
    echo "   -h, --help        Muestra esta ayuda"
    echo ""
    echo "📦 Paquetes apt instalados (sqlite3, python3-pandas, python3-matplotlib, python3-dotenv):"
    echo "   NO se desinstalan automáticamente para no afectar otras herramientas."
    echo "   Si deseas removerlos manualmente: sudo apt remove sqlite3 python3-pandas python3-matplotlib python3-dotenv"
    echo ""
    echo "✅ Ejemplo:"
    echo "   sudo ./uninstall.sh"
    echo "   sudo ./uninstall.sh --all"
}

# Parsear argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --purge-config)
            PURGE_CONFIG=true
            shift
            ;;
        --purge-data)
            PURGE_DATA=true
            shift
            ;;
        --all)
            PURGE_CONFIG=true
            PURGE_DATA=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Error: Opción desconocida '$1'${NC}"
            echo "Usa 'sudo ./uninstall.sh --help' para ver las opciones disponibles."
            exit 1
            ;;
    esac
done

echo "🧹 Iniciando desinstalación del Sistema de Monitoreo de Energía..."
echo ""

# 1. Eliminar binarios
echo "📦 Eliminando scripts de /usr/local/bin..."
if [ -f "$BIN_POWER_EVENT" ]; then
    sudo rm -f "$BIN_POWER_EVENT"
    echo -e "   ${GREEN}✓${NC} $BIN_POWER_EVENT eliminado"
else
    echo -e "   ${YELLOW}⚠${NC} $BIN_POWER_EVENT no existía"
fi

if [ -f "$BIN_GRAFICO_PY" ]; then
    sudo rm -f "$BIN_GRAFICO_PY"
    echo -e "   ${GREEN}✓${NC} $BIN_GRAFICO_PY eliminado"
else
    echo -e "   ${YELLOW}⚠${NC} $BIN_GRAFICO_PY no existía"
fi

if [ -f "$BIN_GRAFICOS_PY" ]; then
    sudo rm -f "$BIN_GRAFICOS_PY"
    echo -e "   ${GREEN}✓${NC} $BIN_GRAFICOS_PY eliminado"
else
    echo -e "   ${YELLOW}⚠${NC} $BIN_GRAFICOS_PY no existía"
fi

echo ""

# 2. Eliminar regla udev
echo "⚡ Eliminando regla udev..."
if [ -f "$RULE_FILE" ]; then
    sudo rm -f "$RULE_FILE"
    echo -e "   ${GREEN}✓${NC} $RULE_FILE eliminado"
    sudo udevadm control --reload-rules
    echo -e "   ${GREEN}✓${NC} Reglas udev recargadas"
else
    echo -e "   ${YELLOW}⚠${NC} $RULE_FILE no existía"
fi

echo ""

# 3. Manejar configuración (si --purge-config o --all)
if [ "$PURGE_CONFIG" = true ]; then
    echo "🔑 Eliminando archivo de configuración..."
    if [ -f "$ENV_FILE" ]; then
        sudo rm -f "$ENV_FILE"
        echo -e "   ${GREEN}✓${NC} $ENV_FILE eliminado"
    else
        echo -e "   ${YELLOW}⚠${NC} $ENV_FILE no existía"
    fi
else
    echo -e "${YELLOW}📋 Conservando archivo de configuración: $ENV_FILE${NC}"
    echo "   (Útil para reinstalación rápida. Contiene el token de Telegram)"
    echo "   Para eliminarlo: sudo ./uninstall.sh --purge-config"
fi

echo ""

# 4. Manejar base de datos (si --purge-data o --all)
if [ "$PURGE_DATA" = true ]; then
    echo "🗄️  Eliminando base de datos..."
    
    # Verificar si es interactivo
    if [ ! -t 0 ]; then
        echo -e "${RED}❌ Error: No se puede eliminar la base de datos en modo no interactivo sin confirmación explícita.${NC}"
        echo "   Si estás ejecutando esto desde un script, considera usar --all con precaución."
        exit 1
    fi
    
    if [ -f "$DB_FILE" ]; then
        echo -e "${RED}⚠️  ADVERTENCIA: Estás a punto de eliminar TODOS los datos históricos de cortes de energía.${NC}"
        read -p "¿Estás seguro de que deseas eliminar $DB_FILE? (s/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            sudo rm -f "$DB_FILE"
            echo -e "   ${GREEN}✓${NC} $DB_FILE eliminado"
        else
            echo -e "   ${YELLOW}⚠${NC} Operación cancelada. La base de datos se conservará."
        fi
    else
        echo -e "   ${YELLOW}⚠${NC} $DB_FILE no existía"
    fi
else
    echo -e "${YELLOW}📊 Conservando base de datos: $DB_FILE${NC}"
    echo "   (Contiene datos valiosos de cortes de energía)"
    echo "   Para eliminarla: sudo ./uninstall.sh --purge-data"
fi

echo ""

# 5. Mensaje final
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ Desinstalación completada${NC}"
echo ""
echo "📦 Paquetes apt que quedaron instalados:"
echo "   • sqlite3"
echo "   • python3-pandas"
echo "   • python3-matplotlib"
echo "   • python3-dotenv"
echo "   (No se desinstalaron para no afectar otras herramientas)"
echo ""
if [ "$PURGE_CONFIG" = false ]; then
    echo "📋 Configuración conservada en: $ENV_FILE"
fi
if [ "$PURGE_DATA" = false ]; then
    echo "📊 Base de datos conservada en: $DB_FILE"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
