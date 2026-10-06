# Power-info

Monitorea los cortes y reanudaciones del servicio eléctrico sobre una laptop o equipo con batería, registrando cada evento en una base SQLite y notificando por Telegram. Incluye un script de generación de gráficas para reportes visuales programados vía `cron`.

## Descripción

Power-info usa el subsistema `power_supply` de Linux para detectar cuándo se conecta o desconecta el adaptador de corriente. En cada evento, calcula la duración del corte, lo persiste en SQLite y envía una notificación a Telegram. El script de gráficas produce un reporte visual con la duración diaria de los cortes y su distribución por hora.

> **Importante:** el proyecto está orientado a equipos con batería (laptops o servidores tipo Mini PC con UPS/batería). En un servidor de escritorio sin batería, el evento del subsistema `power_supply` no existe y la regla `udev` nunca disparará.

## Requisitos previos

- **SO:** Ubuntu/Debian (o derivados) con `systemd` y `udev`.
- **Hardware:** adaptador de corriente detectado por el kernel en `/sys/class/power_supply/` (normalmente `AC` o `ACAD`).
- **Paquetes:** `sqlite3`, `python3-pandas`, `python3-matplotlib`, `python3-dotenv`, `curl`, `flock` (incluido en `util-linux`).
- **Telegram:** un bot creado con `@BotFather` y el/los `chat_id` de los destinatarios (admite varios en `CHAT_ID`, separados por comas).

## Estructura del proyecto

```Plaintext
Power-info/
├── .gitignore
├── LICENSE                (MIT)
├── README.md
├── .env.example
├── schema.sql
├── rules/
│   └── 99-power-supply.rules
├── scripts/
│   ├── power_event.sh
│   └── generar_grafico.py
├── install.sh
└── uninstall.sh
```

## Cómo funciona

```
kernel uevent (power_supply online 0|1)
        │
        ▼
regla udev  →  systemd-run --no-block  →  power_event.sh
                  (desacopla del worker de udev)        │
                                                        ├─ flock /var/lock/power_monitor.lock
                                                        ├─ STATE_FILE /tmp/power_outage_time (deduplica los 2 uevents duales)
                                                        ├─ INSERT en SQLite (/var/db/power_events.db)
                                                        └─ POST a Telegram (sendMessage)
```

- **udev + systemd-run:** la regla `99-power-supply.rules` dispara `systemd-run --no-block` para que el script no muera con el cgroup temporal del worker de udev.
- **Deduplicación:** el kernel puede emitir dos `uevents` por cada maniobra (conexión/desconexión); el `STATE_FILE` y `flock` garantizan un único registro y un único mensaje por evento real.
- **Persistencia:** SQLite (`schema.sql`) define la tabla `cortes` con columnas `id`, `inicio`, `fin`, `duracion_seg` y `creado_en`.
- **Reportes:** `generar_grafico.py` (vía `cron`) lee la base, genera `/tmp/reporte_cortes.png` y lo envía por Telegram con `sendPhoto` a cada destinatario configurado en `CHAT_ID`.

## Instalación del sistema
### Instalación rápida
Hacer ejecutable el Script de instalación automática.

```bash
chmod +x install.sh
```

Luego ejecutar el archivo `install.sh`.

```bash
sudo ./install.sh
```

### Instalación manual
#### Instalación de la base de datos
1. Crear la carpeta contenedores
Se le asignan permisos a SQLite de escritura al archivo `.db` como al directorio donde se aloja.

```bash
sudo mkdir -p /var/db
```

2. Ejecutar el archivo `.sql` con `sqlite3`
Se le pasa el archivo `schema.sql` directamente a `sqlite3` incluyendo la ruta del archivo `.db` de la salida.

```bash
sudo sqlite3 /var/db/power_events.db < schema.sql
```

Si el archivo `/var/db/power_events.db` no existía, SQLite lo creará en este paso y aplicará las sentencias definidas en `schema.sql`.

3. Configurar los permisos
Para evitar errores de permisos cuando diferentes procesos intente escribir en la base de datos.

```bash
# Permiso de lectura/escritura en el archivo de la base de datos
sudo chmod 666 /var/db/power_events.db

# Permiso de ejecución/escritura en la carpeta para manejar journals temporales
sudo chmod 777 /var/db
```

4. Verificación rápida
Puedes verificar que la tabla se creó correctamente consultando los esquemas directamente desde la terminal:

```bash
sqlite3 /var/db/power_events.db ".schema"
```
#### Instalación del script de bash

1. Permisos para el script
Se hace que el script sea ejecutable por el sistema.

```bash
sudo chmod +x /usr/local/bin/power_event.sh
```

2. Crear el archivo `.env`
Crea el archivo .env en una ruta segura, por ejemplo en `/etc/power_monitor.env` o en la carpeta raíz de tu proyecto:

```bash
sudo cp .env.example /etc/power_monitor.env
```

Agrega los valores de tus credenciales. Por último, ajusta los permisos para que solo el sisytema pueda leer este archivo sensible.

```bash
sudo chmod 600 /etc/power_monitor.env
``` 

#### Notificaciones a varias personas

`CHAT_ID` admite uno o varios destinatarios separados por comas. Un solo valor sigue funcionando igual; para notificar a varios chats usa la forma con comas.

```bash
CHAT_ID="12345,67890,11111"
```

Aplica a ambos flujos: los mensajes de corte/reanudación (`power_event.sh`) y el reporte gráfico semanal (`generar_grafico.py`). Cada destinatario recibe el aviso por su chat privado con el bot; si el envío a uno falla, los demás reciben igual y el fallo queda registrado en `journalctl -t power-monitor` indicando el `chat_id`.

**Requisito por destinatario:** cada persona debe haber enviado `/start` al bot antes (así habilita el chat privado), y tú necesitas obtener su `chat_id`. Para varios destinatarios el procedimiento es el mismo, repetido por chat:

1. Pide a cada persona que abra el bot en Telegram y le envíe `/start`.
2. Lista los mensajes recibidos por el bot hasta ahora:

```bash
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" | python3 -m json.tool
```

3. En el JSON, busca el campo `"chat":{"id": <numero>, ...}` de cada persona y copia el número (puede ser positivo para usuarios o negativo para grupos).
4. Junta todos los `chat_id` en `CHAT_ID` separados por comas, sin espacios.

3. Configuración del evento en `udev` (Ejecución automática)
Para que Ubuntu invoque este script automáticamente apenas se desconecte o conecte el cargador de la laptop:

	1. Crear el archivo de reglas de `udev`:
	```bash
	sudo nano /etc/udev/rules.d/99-power-supply.rules
	```
	 2. Se añade esta línea:
	```bash
	SUBSYSTEM=="power_supply", ATTR{online}=="0|1", ACTION=="change", RUN+="/usr/bin/systemd-run --no-block /usr/local/bin/power_event.sh"
	```
	 3. Recargar las reglas en el kernel: 
	 ```bash
	 sudo udevadm control --reload-rules 
	 ```

4. Probar la inserción manualmente
Puedes simular una prueba desconectando el cargador unos segundos y volviéndolo a conectar, o ejecutando manualmente el comando de inserción para comprobar que la base de datos guarde los registros.

```bash
sqlite3 /var/db/power_events.db "SELECT * FROM cortes;"
```
#### Instalar sistema de gráficos
1. Dependencias necesarias
Asegúrate de tener instalados los paquetes de lectura de datos y graficado en Ubuntu.
```bash
sudo apt update && sudo apt install sqlite3 python3-pandas python3-matplotlib python3-dotenv curl -y
```
2. Permisos de ejecución
Asigna los permisos necesarios para ejecutar.
```bash
sudo chmod +x /usr/local/bin/generar_grafico.py
```
3. Prueba del flujo
Para verificar que la lectura del archivo .env, la generación de gráficos y la notificación funcionen.

Ejecutar el script manualmente.
```bash
python3 /usr/local/bin/generar_grafico.py
```
Si la base de datos tiene registros, se generará el archivo `/tmp/reporte_cortes.png` y les llegará una foto con las gráficas al chat de Telegram de cada destinatario configurado en `CHAT_ID`.
#### Configurar cron para tarea programada
1. Abrir la tabla de tareas de `cron` (`crontab`)
Como el script lee la base de datos ubicada en `/var/db/power_events.db` y accede a `/etc/power_monitor.env`, es recomendable agregarlo al `crontab` del usuario `root` o del usuario con permisos suficientes:
```bash
sudo crontab -e
```

2. Sintaxis básica de `Cron`
La estructura de las expresiones de `cron` consta de 5 campos:
```plaintext
┌───────────── minuto (0 - 59)
│ ┌─────────── hora (0 - 23)
│ │ ┌───────── día del mes (1 - 31)
│ │ │ ┌─────── mes (1 - 12)
│ │ │ │ ┌───── día de la semana (0 - 6) (Domingo = 0 o 7)
│ │ │ │ │
* * * * * comando_a_ejecutar
```

3. Ejemplos de programación recomendados
Añade una de las siguientes líneas al final del archivo `crontab`:

	1. **Opción A:** Todos los domingos a las 8:00 PM (Reporte semanal)
	```
	0 20 * * 0 /usr/bin/python3 /usr/local/bin/generar_grafico.py >> /var/log/generar_grafico.log 2>&1
	```
	2. **Opción B:** El primer día de cada mes a las 9:00 AM (Reporte mensual)
	```
	0 9 1 * * /usr/bin/python3 /usr/local/bin/generar_grafico.py >> /var/log/generar_grafico.log 2>&1
	```
	3. **Opción C:** Todos los días a las 10:00 PM (Reporte diario)
	```
	0 22 * * * /usr/bin/python3 /usr/local/bin/generar_grafico.py >> /var/log/generar_grafico.log 2>&1
	```

4. Guardar y verificar
	1. Guardar el archivo: En `nano`, presiona `Ctrl + O`, luego `Enter`, y sal con `Ctrl + X`.
	2. Verificar las tareas activas:
```bash
	sudo crontab -l
	```
 
**Detalle importante en la ejecución:**

Se incluye al final la redirección `>> /var/log/generar_grafico.log 2>&1`. Esto guardará cualquier salida o error en un archivo de registros (log) para que puedas revisar si ocurrió algún problema durante la ejecución desatendida.

## Desinstalación

Usa el script `uninstall.sh` incluido en el repositorio.

```bash
sudo ./uninstall.sh                # Modo seguro (default)
sudo ./uninstall.sh --purge-config # Elimina también /etc/power_monitor.env
sudo ./uninstall.sh --purge-data   # Elimina también /var/db/power_events.db
sudo ./uninstall.sh --all          # Equivale a --purge-config + --purge-data
sudo ./uninstall.sh -h             # Ayuda
```

**Modo seguro (por defecto):** elimina los binarios en `/usr/local/bin/` y la regla udev, pero conserva el archivo de configuración (`/etc/power_monitor.env`) y la base de datos (`/var/db/power_events.db`).

**Nota:** los paquetes `apt` instalados (`sqlite3`, `python3-pandas`, `python3-matplotlib`, `python3-dotenv`) **no** se desinstalan automáticamente para no afectar otras herramientas. Si quieres removerlos: `sudo apt remove sqlite3 python3-pandas python3-matplotlib python3-dotenv`.

## Solución de problemas

- **El script no se ejecuta al desconectar/conectar el cargador.**
  1. Verifica que el kernel detecta tu adaptador: `ls /sys/class/power_supply/`. El nombre suele ser `AC` o `ACAD`.
  2. Comprueba que la regla está cargada simulando un cambio: `sudo udevadm test --action=change /sys/class/power_supply/ACAD` (sustituye `ACAD` por el nombre real si difiere).
  3. Recarga las reglas si las editaste: `sudo udevadm control --reload-rules && sudo udevadm trigger`.
  4. Revisa los servicios generados por `systemd-run`: `journalctl -u 'run-*.service' | grep power_event`.

- **No llegan notificaciones a Telegram.**
  - El script aborta con `exit 1` si falta `/etc/power_monitor.env`. Verifica que el archivo existe y tiene `BOT_TOKEN` y `CHAT_ID` correctos: `sudo cat /etc/power_monitor.env` (permisos `600`).
  - Comprueba la conectividad: `curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe"` (sustituyendo el token).
  - Revisa los reintentos y fallos: `journalctl -t power-monitor`.
  - Si usas varios destinatarios, confirma que `CHAT_ID` tenga el formato exacto `id1,id2,id3` (sin espacios extra ni comillas sueltas) y que cada persona haya enviado `/start` al bot; sin ese paso el bot no puede escribirle.
  - Los `uevents` duales del kernel son normales: el script los deduplica y deberías ver **un** mensaje por evento real. Si ves menos, revisa la regla udev y `STATE_FILE`.

- **No se generan las gráficas.**
  - `generar_grafico.py` lee `/etc/power_monitor.env` (`root:600`), por lo que debe correr como `root` (lo cual hace `cron` desde el `crontab` de root).
  - Verifica que la base tiene datos: `sudo sqlite3 /var/db/power_events.db "SELECT COUNT(*) FROM cortes;"`.
  - La imagen se guarda en `/tmp/reporte_cortes.png`. Revisa también `/var/log/generar_grafico.log` y la salida de `journalctl`.

- **Hora incorrecta en mensajes / gráficas.**
  - El script usa la hora del sistema. Ajusta la zona horaria con `sudo timedatectl set-timezone <Region/Ciudad>` y verifica con `timedatectl`.

- **Mensajes duplicados.**
  - El kernel puede emitir 2 `uevents` por maniobra. El script los deduplica mediante `flock` y `STATE_FILE`; si aún ves duplicados, revisa que la regla udev esté usando exactamente `systemd-run --no-block` (no invocar el script directamente desde `udev`).

## Licencia

MIT. Consulta el archivo `LICENSE` para el texto completo. 