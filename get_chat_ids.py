#!/usr/bin/env python3
"""Lista los chats vinculados al bot de Power-info (id — nombre).
No expone el BOT_TOKEN en la salida. Requiere sudo (lee /etc/power_monitor.env)."""
import json
import urllib.request


def load_env(path="/etc/power_monitor.env"):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


try:
    env = load_env()
    url = f"https://api.telegram.org/bot{env['BOT_TOKEN']}/getUpdates"
    with urllib.request.urlopen(url, timeout=15) as r:
        data = json.load(r)
except Exception:
    print("Error: sin conectividad o respuesta inválida de Telegram (token no válido).")
    raise SystemExit(1)

seen = {}
for upd in data.get("result", []):
    msg = upd.get("message") or upd.get("channel_post") or {}
    chat = msg.get("chat") or {}
    cid = chat.get("id")
    if cid:
        seen[cid] = chat.get("first_name") or chat.get("username") or ""

if not seen:
    print("Aún no hay chats detectados: pide a cada persona enviar /start al bot y vuelve a ejecutar este script.")
else:
    print("Chats detectados (copia el número de la izquierda):")
    for cid, name in sorted(seen.items()):
        print(f"  {cid} — {name}")
