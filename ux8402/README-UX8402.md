# Zenbook Pro 14 Duo OLED (UX8402ZA) en Linux

Variante específica para el **UX8402ZA**. El `duo.sh` del directorio raíz está
escrito para el **UX8406** (Duo 2024/25) y no es aplicable a este modelo: ver
[`../ANALISIS-UX8402ZA.md`](../ANALISIS-UX8402ZA.md) para el detalle.

Probado en Ubuntu 26.04.1 · Kernel 7.0 · GNOME 50 (Wayland) · BIOS UX8402ZA.306.

## Instalación

```bash
cd ux8402
./install-ux8402.sh
```

Ejecútalo **como tu usuario, sin `sudo`**: pide la contraseña solo en los pasos
que la necesitan, y bajo `sudo` los grupos, la configuración y el servicio de
usuario quedarían asignados a root.

El instalador retira primero la instalación anterior (servicios, gancho de
suspensión y las entradas `NOPASSWD` de `/etc/sudoers`, de las cuales una
concedía root sobre un script en `/tmp`). Al terminar hay que **reiniciar el equipo** para que
apliquen los grupos `video` e `input` y para que GNOME cargue la extensión.
Cerrar sesión no basta: el gestor `systemd --user`, que lanza tanto GNOME como
este servicio, suele sobrevivir al cierre de sesión y conserva los grupos
antiguos.

Desinstalar: `./install-ux8402.sh --uninstall`

## Qué hace

| Función | Mecanismo |
|---|---|
| Encender/apagar el ScreenPad Plus | `asus_screenpad/bl_power` — corta la alimentación del panel; GNOME retira `DP-1` y al encender lo restaura con su escala y posición guardadas. En este driver `1` = encendido y `0` = apagado, al revés de la convención del kernel |
| Brillo del ScreenPad | `asus_screenpad/brightness` (0-255) |
| Sincronía de brillo principal → ScreenPad | `inotify` sobre `intel_backlight` con reescalado 0-400 → 0-255 y atenuación configurable |
| Backlight del teclado | `asus::kbd_backlight` (0-3), restaurado en arranque y al despertar |
| Apagado al cerrar la tapa | `/proc/acpi/button/lid/LID0/state` |
| Teclas propias del Duo | listener evdev sobre `Asus WMI hotkeys` |
| Intercambio de ventana entre monitores | extensión GNOME `duo-swap@local` vía D-Bus |

No incluye gestión de WiFi/Bluetooth (no hay teclado desmontable) ni
autorrotación (este chasis no lleva acelerómetro).

## Las tres teclas propias

En Windows, tres teclas del Duo hacen: apagar el ScreenPad, intercambiar
ventanas entre paneles y abrir ScreenXpert/MyASUS (Fn+F12). Bajo Linux **ninguna
funciona por omisión**, por dos motivos distintos que conviene no confundir.

**1. Teclas con keycode fuera del rango de XKB.** `KEY_TOUCHPAD_TOGGLE` = 530,
`KEY_DISPLAYTOGGLE` = 431, `KEY_SELECTIVE_SCREENSHOT` = 634. XKB solo representa
keycodes hasta 255, así que GNOME jamás las recibe y no se pueden asignar con
`gsettings` ni desde Configuración → Teclado.

**2. Teclas que el driver no reconoce.** `asus-nb-wmi` recibe su scancode, no lo
encuentra en su keymap y las entrega como **`KEY_UNKNOWN` (240)**. Como *varias
teclas distintas comparten ese mismo keycode*, es imposible distinguirlas por
keycode: la única referencia fiable es el **scancode crudo** que el driver envía
en `EV_MSC`/`MSC_SCAN` inmediatamente antes. `duo-keys.py` lo captura y permite
mapear por scancode.

Estado en este equipo, según captura real:

| Tecla | Emite | Scancode | Utilizable en GNOME | Cómo se mapea |
|---|---|---|---|---|
| Fn+F12 (ScreenXpert/MyASUS) | `KEY_PROG1` (148) | — | Sí | `key:148` |
| ScreenPad on/off | `KEY_UNKNOWN` (240) | `0x6A` | No | `scan:0x6A` |
| Intercambio de ventanas | `KEY_UNKNOWN` (240) | `0x9C` | No | `scan:0x9C` |
| Toggle del touchpad | `KEY_TOUCHPAD_TOGGLE` (530) | `—` | No | `key:530` |
| Cámara / micrófono | `KEY_CAMERA` (212), `KEY_MICMUTE` (248) | — | Sí | ya gestionadas por GNOME |

Ni `0x9C` ni `0x6A` figuran en el keymap de `asus-nb-wmi`, de ahí que ambos
lleguen como `KEY_UNKNOWN`. Estos valores son los de un UX8402ZA con BIOS 306.

### Identificar los códigos

```bash
/usr/local/lib/zenbook-duo/duo-keys.py --scan
```

Pulsa cada tecla **por separado**. Para cada una imprime el keycode, el scancode
y la línea exacta que hay que copiar en `~/.config/zenbook-duo/keys.conf`:

```
  keycode 240   scancode 0x38       KEY_UNKNOWN              [Asus WMI hotkeys]
      keys.conf:  scan:0x38 = <acción>      (tecla no reconocida por el driver)
```

### Configurar

`~/.config/zenbook-duo/keys.conf` admite tres formas:

```ini
key:148   = menu        # por keycode evdev
scan:0x6A = screenpad   # por scancode crudo (para las KEY_UNKNOWN)
scan:0x9C = swap
148       = menu        # forma abreviada, equivale a key:148
```

El scancode tiene prioridad sobre el keycode, por ser más específico. Acciones
disponibles: `screenpad`, `swap`, `menu`, o cualquier comando literal (por
ejemplo `key:530 = gnome-control-center display`). Una acción vacía desactiva
esa tecla, incluidas las predeterminadas.

Aplicar los cambios: `systemctl --user restart zenbook-duo`

### Alternativa: remapear en el kernel con hwdb

Si prefieres que el propio driver asigne un keycode real a las teclas
`KEY_UNKNOWN` (y que queden disponibles para cualquier aplicación, no solo para
este servicio), puedes declararlas en `/etc/udev/hwdb.d/61-zenbook-duo.hwdb`
usando los scancodes obtenidos con `--scan`:

```
evdev:name:Asus WMI hotkeys:*
 KEYBOARD_KEY_6a=f20
 KEYBOARD_KEY_9c=f21
```

Seguido de `sudo systemd-hwdb update && sudo udevadm trigger`. Elegir teclas
`F20`–`F24` las mantiene dentro del rango de XKB, con lo que sí pueden asignarse
desde Configuración → Teclado → Atajos personalizados. Es más limpio, pero
depende de que el scancode sea estable entre versiones de firmware.

### Por qué el intercambio de ventanas necesita una extensión

Bajo Wayland ningún proceso externo puede mover una ventana: solo el compositor
conoce su geometría. `org.gnome.Shell.Introspect.GetWindows` deniega el acceso a
clientes no privilegiados y `Eval` está deshabilitado en las compilaciones de
producción. La extensión `duo-swap@local` expone un único método D-Bus
(`org.zenbook.Duo.SwapMonitor`) que mueve la ventana enfocada al siguiente
monitor preservando su estado maximizado.

## Uso manual

```bash
duo status                 # estado del hardware
duo screenpad toggle       # alternar el ScreenPad
duo screenpad 120          # fijar brillo (0-255)
duo kbd 2                  # backlight del teclado (0-3)
duo swap                   # mover la ventana enfocada al otro monitor
duo menu                   # panel de control
```

Registro: `$XDG_RUNTIME_DIR/zenbook-duo/duo.log`

## Configuración

`~/.config/zenbook-duo/duo.conf`

| Clave | Por defecto | Efecto |
|---|---|---|
| `DEFAULT_KB_BACKLIGHT` | `1` | Nivel del teclado en arranque y resume |
| `SYNC_BRIGHTNESS` | `true` | Replicar brillo principal en el ScreenPad |
| `SCREENPAD_DIM` | `85` | % del brillo principal aplicado al ScreenPad |
| `SCREENPAD_MIN` | `5` | Brillo mínimo mientras esté encendido |
| `SCREENPAD_OFF_ON_LID` | `true` | Apagar el ScreenPad al cerrar la tapa |
| `SCREENPAD_OFF_ON_BATTERY` | `false` | Apagar el ScreenPad al desconectar la corriente |

## Pendiente de validación

- Mapeo táctil de `ELAN9009` (touch y lápiz del ScreenPad) sobre `DP-1`.
