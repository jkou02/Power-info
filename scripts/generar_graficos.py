#!/usr/bin/env python3
import os
import sqlite3
import subprocess
import pandas as pd
import matplotlib.pyplot as plt

ENV_FILE = "/etc/power_monitor.env"
OUTPUT_IMAGE = "/tmp/reporte_cortes.png"

# ==========================================
# CARGAR ARCHIVO .ENV
# ==========================================
def load_env(env_path):
    """Carga las variables de entorno desde el archivo .env."""
    if not os.path.exists(env_path):
        print(f"Error: No se encontró el archivo {env_path}")
        return

    # Intentar usar python-dotenv si está disponible
    try:
        from dotenv import load_dotenv
        load_dotenv(env_path)
    except ImportError:
        # Fallback: parseo manual de líneas KEY=VALUE
        with open(env_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, val = line.split('=', 1)
                    os.environ[key.strip()] = val.strip().strip('"').strip("'")

# Cargar las credenciales
load_env(ENV_FILE)

DB_PATH = os.getenv("DB_PATH", "/var/db/power_events.db")
BOT_TOKEN = os.getenv("BOT_TOKEN")
CHAT_ID = os.getenv("CHAT_ID")

# ==========================================
# GENERAR GRÁFICAS Y ENVIAR REPORTES
# ==========================================
def generar_reporte():
    if not os.path.exists(DB_PATH):
        print(f"La base de datos {DB_PATH} no existe.")
        return

    # Conectar a la base de datos
    conn = sqlite3.connect(DB_PATH)
    query = "SELECT inicio, fin, duracion_seg FROM cortes ORDER BY inicio ASC"
    df = pd.read_sql_query(query, conn)
    conn.close()

    if df.empty:
        print("No hay registros suficientes para generar la gráfica.")
        return

    # Procesar fechas y tiempos
    df['inicio'] = pd.to_datetime(df['inicio'])
    df['duracion_min'] = df['duracion_seg'] / 60.0
    df['fecha'] = df['inicio'].dt.strftime('%d/%m')
    df['hora_corte'] = df['inicio'].dt.hour

    # Configuración de estilo
    plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    # Gráfico 1: Duración por fecha
    axes[0].bar(df['fecha'], df['duracion_min'], color='#e74c3c', edgecolor='black', alpha=0.8)
    axes[0].set_title("Duración de Cortes por Día (Minutos)")
    axes[0].set_xlabel("Fecha (Día/Mes)")
    axes[0].set_ylabel("Duración (minutos)")
    axes[0].grid(True, linestyle='--', alpha=0.6)

    # Gráfico 2: Frecuencia según la hora del día
    axes[1].hist(df['hora_corte'], bins=range(0, 25), color='#3498db', edgecolor='black', alpha=0.8)
    axes[1].set_title("Distribución de Cortes por Hora del Día")
    axes[1].set_xlabel("Hora del Día (0 - 23h)")
    axes[1].set_ylabel("Frecuencia de Cortes")
    axes[1].set_xticks(range(0, 24, 2))
    axes[1].grid(True, linestyle='--', alpha=0.6)

    plt.tight_layout()
    plt.savefig(OUTPUT_IMAGE, dpi=300)
    plt.close()
    print(f"Gráfico generado exitosamente en: {OUTPUT_IMAGE}")

    # Enviar foto por Telegram si están definidos BOT_TOKEN y CHAT_ID
    if BOT_TOKEN and CHAT_ID:
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendPhoto"
        cmd = [
            "curl", "-s", "-X", "POST", url,
            "-F", f"chat_id={CHAT_ID}",
            "-F", f"photo=@{OUTPUT_IMAGE}",
            "-F", "caption=📊 Reporte visual de cortes del servicio eléctrico"
        ]
        subprocess.run(cmd)
        print("Reporte enviado a Telegram correctamente.")
    else:
        print("Advertencia: BOT_TOKEN o CHAT_ID no están configurados en el .env.")

if __name__ == "__main__":
    generar_reporte()