# Power-info
Uso de información de la laptop para identificar cuando se realizan los cortes y reanudación del servicio eléctrico.

## Instalación del sistema

### Instalación rápida
Hacer ejecutable el script de instalación automatica.

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

3. Configuración del evento en `udev` (Ejecución automática)
Para que Ubuntu invoque este script automáticamente apenas se desconecte o conecte el cargador de la laptop:

 1. Crear el archivo de reglas de `udev`:
 ```bash
 sudo nano /etc/udev/rules.d/99-power-supply.rules
 ```
 2. Se añade esta línea:
 
 ```bash
 SUBSYSTEM=="power_supply", ATTR{online}=="0|1", ACTION=="change", RUN+="/usr/local/bin/power_event.sh"
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
sudo apt update && sudo apt install python3-pandas python3-matplotlib python3-dotenv -y
```

2. Permisos de ejecución
Asigna los permisos necesarios para ejecutar.

```bash
sudo chmod +x /usr/local/bin/generar_grafico.py
```

3. Prueba del flujo
Para verificar que la lectura del archivo .env, la generación de gráficos y la notificación funcionen.
 
 1. Ejecutar el script manualmente.
 
 ```bash
 python3 /usr/local/bin/generar_grafico.py
 ```
 2. Si la base de datos tiene registros, se generará el archivo `/tmp/reporte_cortes.png` y te llegará una foto con las gráficas al chat de Telegram.

#### Configurar cron para tarea programada

1. Abrir la tabla de tareas de `cron` (`crontab`)
Como el script lee la base de datos ubicada en `/var/db/power_events.db` y accede a `/etc/power_monitor.env`, es recomendable agregarlo al `crontab` del usuario `root` o del usuario con permisos suficientes:

```bash
sudo crontab -e
```

2. Sintaxis básica de Cron
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