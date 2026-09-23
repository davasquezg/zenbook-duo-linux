# Evaluación de `zenbook-duo-linux` sobre ASUS Zenbook Pro 14 Duo OLED (UX8402ZA)

**Fecha:** 2026-09-16
**Equipo:** `UX8402ZA` · BIOS `UX8402ZA.306` · Ubuntu 26.04.1 LTS · Kernel 7.0.0-31 · GNOME Shell 50.1 (Wayland)
**Upstream:** https://github.com/Fmstrat/zenbook-duo-linux (rama local `main-1`, 4 commits)

---

## 1. Conclusión ejecutiva

El script upstream está escrito para el **Zenbook Duo 2024/2025 (UX8406)**: dos paneles eDP completos
y un **teclado Bluetooth desmontable** que se detecta por USB. El UX8402ZA es una arquitectura
**distinta**: panel principal + *ScreenPad Plus* secundario, teclado **integrado y no desmontable**.

Prácticamente **toda la lógica central del script no aplica y, además, produce efectos colaterales
activos hoy**. El servicio está corriendo (`zenbook-duo-user.service`, PID 7618) y en el log se ve el
bucle degradado: cada evento USB se interpreta como "teclado desacoplado".

| Supuesto del upstream | Realidad en UX8402ZA | Estado |
|---|---|---|
| Teclado USB `Zenbook Duo Keyboard` | No existe (teclado PS/2 `AT Translated Set 2`) | ❌ rompe todo el flujo |
| Pantalla inferior = `eDP-2` | ScreenPad = **`DP-1`** (BOE 13", 2880x864@120) | ❌ |
| Backlight inferior = `card1-eDP-2-backlight` | **`/sys/class/backlight/asus_screenpad`** (max 255) | ❌ |
| Backlight teclado por USB HID + Python | **`/sys/class/leds/asus::kbd_backlight`** (0-3) | ❌ innecesario |
| Acelerómetro para autorrotación | **No hay acelerómetro** (solo `prox`, `als`, `hinge`) | ❌ proceso inútil |
| BT/WiFi ligados al acople del teclado | Sin teclado desmontable | ❌ efecto colateral dañino |

**Veredicto:** no es cuestión de "ajustar variables". Hay que reescribir el núcleo del script o
sustituirlo por una versión específica del modelo. Aproximadamente el 70 % del código es inaplicable.

---

## 2. Hardware detectado (línea base verificada)

```
DRM          card1-eDP-1  connected   SDC 0x416d  2880x1800@120  (principal, HDR/bt2100)
             card1-DP-1   connected   BOE 0x0a8d  2880x864@120   (ScreenPad Plus)
             card1-DP-2/DP-3/HDMI-A-1  disconnected

Backlight    intel_backlight     max=400  cur=400      -> eDP-1
             asus_screenpad      max=255  actual=82  bl_power=1   -> DP-1

LEDs         asus::kbd_backlight   max=3  cur=2

IIO          iio:device0 prox | iio:device1 als | iio:device2 hinge   (SIN accel)

Input        ELAN9008 -> touch + stylus panel superior
             ELAN9009 -> touch + stylus + touchpad ScreenPad
             "Asus WMI hotkeys" (event18) -> teclas Fn
             ASUE1212 -> touchpad físico

Plataforma   asus_nb_wmi, asus_wmi, asus_armoury
             platform_profile: quiet balanced [performance]
             throttle_thermal_policy disponible
```

Escalado actual en `~/.config/monitors.xml`: eDP-1 **1.667** + HDR (`colormode bt2100`),
DP-1 **1.5**, posición `(0,1080)`.

---

## 3. Defectos concretos del script en este equipo

### 3.1 CRÍTICO — Bluetooth y WiFi forzados en cada evento USB
`duo.sh:250-270` (`duo-check-monitor`). Como `KEYBOARD_ATTACHED` es siempre `false`, se ejecuta
incondicionalmente la rama "detached":

```bash
rfkill unblock bluetooth
[ "${WIFI_BEFORE}" = enabled ] && nmcli radio wifi on
```

`duo-watch-monitor` dispara con `inotifywait -e attrib /dev/bus/usb/*/`, es decir **cualquier**
conexión USB (o cambio de atributos, incluido el polling del hub). Efecto real: **es imposible dejar
el Bluetooth apagado**; se reactiva solo. Confirmado en `/tmp/duo/duo.log` (10:45:04, 10:45:18,
10:52:59 — tres reactivaciones en 8 minutos).

**Acción:** eliminar por completo la gestión de rfkill/nmcli y los watchers
`duo-watch-wifi` / `duo-watch-bluetooth` / `duo-watch-lock`. No tienen sentido sin teclado desmontable.

### 3.2 CRÍTICO — `gdctl set` destruiría la configuración de pantallas
`duo-check-monitor` y todas las ramas de rotación invocan:

```bash
gdctl set --logical-monitor --primary --scale ${SCALE} --monitor eDP-1 \
          --logical-monitor --scale ${SCALE} --monitor eDP-2 --below eDP-1
```

Tres problemas simultáneos:
1. **`eDP-2` no existe** → el comando falla; el ScreenPad nunca se encendería.
2. `SCALE` es `DEFAULT_SCALE` (**1**), no la escala real (1.667 / 1.5) → al ejecutarse resetearía el
   escalado de ambas pantallas.
3. `gdctl set` **no preserva `colormode bt2100` ni el modo 120 Hz** → se perdería **HDR** y la tasa de
   refresco en eDP-1.

Hoy no llega a ejecutarse porque `MONITOR_COUNT` ya es 2, pero **en el arranque sí se disparó**:
el log muestra `Monitor count: 0` a las 09:46:03 (gdctl aún sin sesión gráfica), lo que entra en la
rama `< 2` y lanza el `gdctl set` roto. Es una bomba de relojería en cada boot/resume.

**Acción:** conector `DP-1`; leer escala y modo reales desde `gdctl show`/`monitors.xml` en vez de
hardcodear; o preferiblemente **no reconfigurar monitores**, sino usar `bl_power` del ScreenPad
(ver §4.2), que no toca la topología ni el HDR.

### 3.3 ALTO — Sincronización de brillo apunta a un backlight inexistente
`duo-sync-display-backlight` escribe en `/sys/class/backlight/card1-eDP-2-backlight/brightness`.
En este equipo el destino es `asus_screenpad` **y los rangos no coinciden**: origen 0-400, destino
0-255. Requiere reescalado:

```bash
SP=$(( CUR_BRIGHTNESS * 255 / 400 ))
```

Además la condición `[ "${KEYBOARD_ATTACHED}" = false ]` (siempre verdadera aquí) es la correcta por
accidente, pero debe sustituirse por "ScreenPad encendido".

Nota: `asus_screenpad/brightness` contiene hoy **130898**, un valor fuera de rango (max 255) escrito
por algún componente; `actual_brightness` reporta 82. Conviene normalizarlo al iniciar.

### 3.4 ALTO — Backlight de teclado vía USB HID: código muerto
`duo.sh:28-140` genera `/tmp/duo/backlight.py` **solo si** `lsusb | grep 'Zenbook Duo Keyboard'`
devuelve algo. Aquí nunca ocurre → el archivo no se crea → cada llamada a `duo-set-kb-backlight`
ejecuta `sudo python3 /tmp/duo/backlight.py N` sobre un fichero inexistente y falla silenciosamente
(`>/dev/null`). Se invoca en boot, resume, suspend y en cada evento USB.

**Acción:** sustituir las ~115 líneas de Python embebido por una escritura sysfs:

```bash
echo "${1}" > /sys/class/leds/asus::kbd_backlight/brightness
```

El rango coincide (0-3). Con una regla udev (§5) ni siquiera hace falta `sudo`.

### 3.5 ALTO — Riesgo de seguridad en `setup.sh`
```bash
addSudoers "${USER} ALL=NOPASSWD:${PYTHON3} /tmp/duo/backlight.py *"
```
Concede ejecución **sin contraseña como root** de un script en `/tmp`, ruta escribible por cualquier
usuario local. Cualquier proceso del usuario (o de otro usuario, según permisos) puede reescribir
`backlight.py` y obtener root. En este modelo la entrada es, además, **completamente innecesaria**.

**Acción:** eliminar ambas entradas de `/etc/sudoers` y no añadirlas. Verificar con
`sudo grep -n duo /etc/sudoers`.

### 3.6 MEDIO — Autorrotación sin sensor
`duo-watch-rotate` lanza `monitor-sensor --accel`. Verificado: los IIO disponibles son `prox`, `als`
y `hinge`; **no hay acelerómetro**. El proceso queda colgado sin emitir nada. Es un portátil
clamshell, no un convertible: la función no aplica. Además `xargs -I '{}' "$0" '{}'` reinvoca el
script por cada evento — patrón frágil.

**Acción:** eliminar `duo-watch-rotate` y las ramas `left-up/right-up/bottom-up/normal`.

### 3.7 MEDIO — Disparador equivocado para el toggle del ScreenPad
El evento natural en UX8402ZA no es USB sino la tecla **Fn+F6** (`Asus WMI hotkeys`, `event18`) y,
secundariamente, el cierre de tapa (`Lid Switch`, `event0`). El bucle `inotifywait` sobre
`/dev/bus/usb` debe reemplazarse por un *listener* de esas fuentes.

### 3.8 BAJO — Higiene
- `/tmp/duo/status` es escribible por el usuario y se hace `source` → inyección de código en el
  servicio. Usar `/run/user/$UID/duo/` y parseo estricto.
- Unidad systemd desincronizada: `systemctl` avisa *"unit file changed on disk"* → falta
  `daemon-reload`.
- `ExecStartPre=/bin/sleep 3` como sincronización con la sesión gráfica es frágil; mejor
  `After=graphical-session.target` + `PartOf=graphical-session.target` y reintento de `gdctl`.
- `duo-watch-lock` duplica la lógica de Bluetooth con un comentario/log incorrecto (dice NETWORK).

---

## 4. Funcionalidad realmente útil en este modelo

Lo que sí tiene sentido implementar, todo verificado como disponible:

### 4.1 Backlight del teclado
```bash
echo 2 | tee /sys/class/leds/asus::kbd_backlight/brightness   # 0-3
```
Restaurar nivel en boot y tras resume. GNOME ya gestiona Fn+F3/F4.

### 4.2 Encendido/apagado del ScreenPad sin tocar la topología
```bash
echo 1 > /sys/class/backlight/asus_screenpad/bl_power   # apagar (FB_BLANK_POWERDOWN)
echo 0 > /sys/class/backlight/asus_screenpad/bl_power   # encender
```
Ventaja frente a `gdctl set`: **no altera escalas, posiciones, HDR ni modos**, y es instantáneo.
Complementar con `brightness` para el nivel.

### 4.3 Sincronía de brillo principal → ScreenPad
```bash
inotifywait -e modify /sys/class/backlight/intel_backlight/brightness
echo $(( $(cat /sys/class/backlight/intel_backlight/brightness) * 255 / 400 )) \
  > /sys/class/backlight/asus_screenpad/brightness
```
Conviene un factor de atenuación configurable (el ScreenPad suele preferirse más tenue) y clamp a
`[0,255]`.

### 4.4 Mapeo del touch del ScreenPad *(pendiente de validar)*
`ELAN9009` (touch + stylus + touchpad del ScreenPad) debe quedar asociado a `DP-1`. Mutter en Wayland
lo hace por EDID de forma automática en la mayoría de casos, pero conviene verificarlo tocando el
panel inferior y comprobando dónde aparece el puntero. Si falla, se corrige con
`gsettings set org.gnome.desktop.peripherals.touchscreen:<ruta-dispositivo> output`.

### 4.5 Perfiles térmicos (extra, no cubierto por upstream)
`platform_profile` (`quiet|balanced|performance`) y `throttle_thermal_policy` están expuestos por
`asus_nb_wmi`. Actualmente en `performance`. Es candidato a conmutación automática según AC/batería.

### 4.6 Ahorro de energía
Apagar el ScreenPad al desconectar el cargador o al cerrar la tapa (`Lid Switch`). En este chasis el
ScreenPad es un consumidor relevante y no se apaga solo.

---

## 5. Plan de modificación propuesto

Recomendación: **no parchear el upstream línea a línea**, sino mantener `duo.sh` intacto como
referencia y crear `duo-ux8402.sh` específico del modelo (~80 líneas frente a 370). Es más
mantenible que rellenar el script actual de condicionales por modelo.

**Fase 1 — Detener el daño (inmediato)**
1. `systemctl --user stop/disable zenbook-duo-user.service` y `sudo systemctl disable zenbook-duo.service`.
2. Eliminar el symlink `/lib/systemd/system-sleep/duo`.
3. Retirar las dos entradas `NOPASSWD` de `/etc/sudoers` (§3.5).
4. Normalizar `asus_screenpad/brightness` al rango 0-255.

**Fase 2 — Acceso sin privilegios (regla udev)**
`/etc/udev/rules.d/99-zenbook-duo.rules`:
```
ACTION=="add", SUBSYSTEM=="leds", KERNEL=="asus::kbd_backlight", \
  RUN+="/bin/chgrp video /sys/class/leds/%k/brightness", \
  RUN+="/bin/chmod g+w /sys/class/leds/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="asus_screenpad", \
  RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", \
  RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness", \
  RUN+="/bin/chgrp video /sys/class/backlight/%k/bl_power", \
  RUN+="/bin/chmod g+w /sys/class/backlight/%k/bl_power"
```
Con el usuario en el grupo `video` desaparece toda necesidad de `sudo`.

**Fase 3 — `duo-ux8402.sh`**
Un único servicio de usuario con tres funciones:
- restauración de backlight de teclado en boot/resume;
- watcher de brillo `intel_backlight` → `asus_screenpad` con reescalado;
- toggle del ScreenPad vía `bl_power`, atado a Fn+F6 (atajo GNOME propio o listener de `event18`).

Sin rfkill, sin nmcli, sin Python/USB, sin `gdctl set`, sin rotación.

**Fase 4 — Opcionales**
Validación del mapeo táctil (§4.4), perfiles térmicos (§4.5), apagado por tapa/batería (§4.6).

---

## 6. Sobre el fix de audio de PipeWire (commit `b1a0e52`)

`pw-metadata -n settings 0 clock.force-quantum 512` es independiente del modelo y sigue siendo
válido. Para hacerlo persistente es preferible un *drop-in* de configuración en lugar de ejecutarlo
tras cada arranque:

```
~/.config/pipewire/pipewire.conf.d/99-quantum.conf
context.properties = {
    default.clock.quantum       = 512
    default.clock.min-quantum   = 512
}
```

---

## 7. Notas de verificación

Todos los datos de §2 proceden de inspección directa del equipo (`/sys/class/drm`,
`/sys/class/backlight`, `/sys/class/leds`, `/sys/bus/iio/devices`, `/proc/bus/input/devices`,
`lsusb -t`, `gdctl show`, `~/.config/monitors.xml`, `journalctl`/`/tmp/duo/duo.log`).
No se ha modificado ningún archivo del sistema durante esta evaluación.

Captura de teclas realizada sobre `event18` (`Asus WMI hotkeys`):

| Tecla | Keycode | Accesible desde GNOME |
|---|---|---|
| Fn+F12 (ScreenXpert/MyASUS) | `KEY_PROG1` (148) | sí |
| ScreenPad on/off | `KEY_UNKNOWN` (**240**) | no |
| Intercambio de ventanas | `KEY_UNKNOWN` (**240**) | no |
| Toggle del touchpad | `KEY_TOUCHPAD_TOGGLE` (530) | no, excede XKB |
| Cámara / micrófono | 212 / 248 | sí |

`KEY_UNKNOWN` indica que `asus-nb-wmi` recibe el scancode pero no lo tiene en su
keymap. Dos teclas distintas comparten ese keycode, así que solo el scancode
crudo (`EV_MSC`/`MSC_SCAN`) permite separarlas — de ahí el soporte de mapeo por
scancode en `ux8402/duo-keys.py`. Alternativa a nivel de kernel: declararlas en
`/etc/udev/hwdb.d/` con `KEYBOARD_KEY_<scancode>=f20…f24`.

Sin validar aún (requiere prueba interactiva):
- scancode concreto de la tecla del ScreenPad y de la de intercambio;
- comportamiento real de `bl_power` en este firmware (BIOS 306);
- mapeo táctil de `ELAN9009` sobre `DP-1`.
