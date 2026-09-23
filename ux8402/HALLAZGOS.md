# Hallazgos y estado del trabajo — Zenbook Duo UX8402ZA

Documento de continuidad. Recoge lo averiguado sobre el hardware, lo que ya está
escrito, lo que falta y los comandos exactos para retomar.

**Última actualización:** 2026-09-23
**Equipo:** ASUS `UX8402ZA` (Zenbook Pro 14 Duo OLED, 2022) · BIOS `UX8402ZA.306`
**Sistema:** Ubuntu 26.04.1 · Kernel 7.0.0-31 · GNOME Shell 50.1 · Wayland
**Repo:** `davasquezg/zenbook-duo-linux` (fork de `Fmstrat/zenbook-duo-linux`), rama `main`

---

## 1. Hallazgo central

El `duo.sh` del upstream está escrito para el **UX8406** (Zenbook Duo 2024/25:
dos paneles eDP y teclado Bluetooth desmontable). El UX8402ZA es otra
arquitectura: panel principal + ScreenPad Plus, teclado integrado. Alrededor del
**70 % del script no aplica**, y lo que sí se ejecuta produce efectos
colaterales.

| Supuesto upstream | Realidad UX8402ZA |
|---|---|
| Teclado USB `Zenbook Duo Keyboard` | No existe (`AT Translated Set 2 keyboard`) |
| Pantalla inferior `eDP-2` | **`DP-1`** (BOE 13", 2880x864@120) |
| Backlight `card1-eDP-2-backlight` | **`/sys/class/backlight/asus_screenpad`** (0-255) |
| Backlight teclado por USB HID + Python | **`/sys/class/leds/asus::kbd_backlight`** (0-3) |
| Acelerómetro para autorrotación | No hay (`prox`, `als`, `hinge`) |

Análisis completo: [`../ANALISIS-UX8402ZA.md`](../ANALISIS-UX8402ZA.md)

---

## 2. Inventario de hardware verificado

```
DRM          card1-eDP-1  SDC 0x416d  2880x1800@120  principal, HDR (colormode bt2100)
             card1-DP-1   BOE 0x0a8d  2880x864@120   ScreenPad Plus

Backlight    intel_backlight   max=400   -> eDP-1
             asus_screenpad    max=255   -> DP-1   (bl_power: 1=on, 0=off — invertido, ver §3.4)

LEDs         asus::kbd_backlight  max=3

IIO          iio:device0 prox | iio:device1 als | iio:device2 hinge   (SIN accel)

Input        event3   AT Translated Set 2 keyboard
             event18  Asus WMI hotkeys          <- teclas propias del Duo
             ELAN9008 touch + lápiz panel superior
             ELAN9009 touch + lápiz + touchpad del ScreenPad
             ASUE1212 touchpad físico

Plataforma   asus_nb_wmi, asus_wmi, asus_armoury
             platform_profile: quiet balanced performance
             throttle_thermal_policy disponible

Escalado     ~/.config/monitors.xml: eDP-1 1.667 + HDR · DP-1 1.5 en (0,1080)
```

---

## 3. Los dos motivos por los que las teclas del Duo no funcionan

Este es el hallazgo técnico que condiciona todo el diseño. **No se confunden:
son dos problemas distintos.**

### 3.1 Keycodes fuera del rango de XKB

`KEY_TOUCHPAD_TOGGLE` = 530, `KEY_DISPLAYTOGGLE` = 431,
`KEY_SELECTIVE_SCREENSHOT` = 634. XKB solo representa keycodes hasta **255**, de
modo que GNOME nunca los recibe y **no se pueden asignar con `gsettings`** ni
desde Configuración → Teclado.

### 3.2 Scancodes que el driver no reconoce

`asus-nb-wmi` recibe el scancode, no lo encuentra en su keymap y entrega
**`KEY_UNKNOWN` (240)**. Como *varias teclas distintas colapsan en ese mismo
keycode*, es imposible distinguirlas por keycode. La única referencia fiable es
el **scancode crudo** que el driver emite en `EV_MSC`/`MSC_SCAN` justo antes del
`EV_KEY`.

### 3.3 Captura realizada (2026-09-16) — mapeo cerrado

| Tecla | Emite | Scancode | ¿La ve GNOME? | Mapeo |
|---|---|---|---|---|
| Fn+F12 (ScreenXpert/MyASUS) | `KEY_PROG1` (148) | — | sí | `key:148` ✅ |
| ScreenPad on/off | `KEY_UNKNOWN` (240) | **`0x6A`** | no | `scan:0x6A` ✅ |
| Intercambio de ventanas | `KEY_UNKNOWN` (240) | **`0x9C`** | no | `scan:0x9C` ✅ |
| Toggle del touchpad | `KEY_TOUCHPAD_TOGGLE` (530) | — | no | `key:530`, libre |
| Cámara / micrófono | 212 / 248 | — | sí | ya gestionadas por GNOME |

Dos observaciones sobre esta captura:

- **No** aparecieron `KEY_DISPLAYTOGGLE` (431) ni `KEY_SWITCHVIDEOMODE` (227),
  pese a estar declarados en las capacidades del dispositivo. Eran los
  candidatos iniciales y quedaron descartados.
- Ni `0x9C` ni `0x6A` figuran en el keymap de `asus-nb-wmi`, lo que confirma el
  diagnóstico de §3.2. Son valores de un UX8402ZA con BIOS 306 y podrían variar
  con otras versiones de firmware.

**Correspondencia verificada (2026-09-23):** la primera asignación, deducida del
orden de pulsación durante la captura, estaba cruzada. Confirmado pulsando cada
tecla por separado: `0x6A` = ScreenPad on/off, `0x9C` = intercambio de ventanas.

### 3.4 `bl_power` invertido en `asus_screenpad` (verificado 2026-09-23)

El driver `asus-wmi` no sigue la convención del kernel para `bl_power`
(0 = encendido). Pasa el valor crudo del firmware:

```c
/* update_screenpad_bl_status() */
if (bd->props.power)   -> SCREENPAD_POWER=1 + SCREENPAD_LIGHT=brillo   // enciende
if (!bd->props.power)  -> SCREENPAD_POWER=0                            // corta
/* asus_screenpad_init() */
bd->props.power = power;   // 1 = alimentado
```

Por eso arranca con `bl_power=1` y el panel encendido: no es un estado
incoherente. Consecuencias observadas:

- `bl_power=0` **corta la alimentación**: `DP-1` pasa a `disconnected` y GNOME
  retira el monitor. Al volver a `1`, el enlace se recupera solo y mutter
  restaura escala (1.5) y posición (0,1080) desde `monitors.xml`. No hace falta
  `echo detect` sobre el conector (no tiene efecto con el panel sin corriente).
- Con el panel sin alimentación, `actual_brightness` devuelve el último nivel
  guardado, de modo que el estado solo puede deducirse de `bl_power`.
- La primera versión del script usaba la semántica estándar, así que "apagar"
  dejaba el panel alimentado a brillo 0 y "encender" le cortaba la corriente:
  la tecla apagaba la pantalla pero nunca la volvía a encender.

---

## 4. Defectos activos del script upstream

Estaba corriendo como `zenbook-duo-user.service` y sigue instalado.

1. **Bluetooth y WiFi forzados.** `KEYBOARD_ATTACHED` es siempre `false`, así que
   cada evento USB ejecuta `rfkill unblock bluetooth` + `nmcli radio wifi on`.
   Tres reactivaciones en 8 minutos en el log. Es imposible dejar el BT apagado.
2. **`gdctl set` destructivo.** Apunta a `eDP-2` (inexistente), fuerza
   `--scale 1` y **no preserva `colormode bt2100` ni 120 Hz**. Se dispara en
   arranque, cuando `gdctl` aún no tiene sesión (`Monitor count: 0` en el log).
3. **Sincronía de brillo al destino equivocado:** escribe en
   `card1-eDP-2-backlight`, y además no reescala 0-400 → 0-255.
4. **Backlight de teclado muerto:** genera `/tmp/duo/backlight.py` solo si
   detecta el teclado USB; como nunca lo detecta, cada llamada falla en silencio.
5. **Riesgo de seguridad:** `setup.sh` añade a `/etc/sudoers`
   `NOPASSWD: python3 /tmp/duo/backlight.py *` — root sobre una ruta escribible
   por el usuario. Innecesario en este modelo.
6. **Autorrotación sin sensor:** `monitor-sensor --accel` no emite nada.
7. **`/tmp/duo/status` se hace `source`** desde el servicio: inyección de código.

---

## 5. Qué está escrito (sin instalar)

Nada se ha instalado todavía: el instalador requiere `sudo` interactivo.

```
ux8402/
├── duo-ux8402.sh                    demonio: ScreenPad, brillo, teclado, tapa
├── duo-keys.py                      listener evdev (keycode + scancode)
├── duo-swap.sh                      cliente D-Bus del intercambio de ventanas
├── duo-menu.sh                      panel zenity (equivalente a ScreenXpert)
├── 99-zenbook-duo-ux8402.rules      udev: acceso por grupo 'video', sin sudo
├── gnome-extension/duo-swap@local/  extensión GNOME (metadata.json, extension.js)
├── install-ux8402.sh                instala / --uninstall / --purge-old
├── README-UX8402.md                 documentación de uso
└── HALLAZGOS.md                     este documento
```

Decisiones de diseño y su motivo:

- **`bl_power` en lugar de `gdctl`** para encender/apagar el ScreenPad: corta
  la alimentación del panel y deja que mutter retire y restaure `DP-1` con su
  configuración guardada, sin forzar escalas ni modos como `gdctl set`.
  Semántica invertida: ver §3.4.
- **Extensión GNOME para el intercambio de ventanas:** bajo Wayland ningún
  proceso externo puede mover una ventana. Verificado:
  `org.gnome.Shell.Introspect.GetWindows` devuelve `AccessDenied` y `Eval` está
  deshabilitado. La extensión expone `org.zenbook.Duo.SwapMonitor`.
  En Mutter 18 (GNOME 49+) `Meta.Window.get_maximized()` ya no existe
  (ahora `get_maximize_flags()`, y `maximize()`/`unmaximize()` sin argumentos);
  la extensión admite ambas API. Verificado por introspección del typelib
  `Meta-18` el 2026-09-23.
- **udev + grupo `video`** en lugar de entradas en `sudoers`.
- **Grupo `input`** para leer `event18`, imprescindible por §3.

Validado: sintaxis de bash, python, JSON y JS (gjs); `duo status` responde
correctamente; el parser de `keys.conf` resuelve bien `key:`, `scan:`, la forma
abreviada, la precedencia del scancode y la desactivación con acción vacía.

---

## 6. Pendientes

### Mapeo de teclas — cerrado

`~/.config/zenbook-duo/keys.conf` ya está escrito con los tres códigos
confirmados y la correspondencia verificada (§3.3). Para reidentificar una
tecla en cualquier momento:

```bash
sudo ./ux8402/duo-keys.py --scan
```

### Instalación

```bash
cd ux8402 && ./install-ux8402.sh
```

Retira lo anterior (servicios, gancho de suspensión, entradas de `sudoers` con
copia de seguridad y `visudo -c`), instala en `/usr/local/lib/zenbook-duo/`,
crea la regla udev, añade a los grupos `video` e `input`, registra el servicio de
usuario y la extensión. **Requiere reiniciar**: cerrar sesión no basta, porque `systemd --user`
(que lanza GNOME y el servicio) sobrevive al cierre y conserva los grupos
antiguos. Comprobado el 2026-09-23.

### Verificaciones tras instalar

- ~~`bl_power`~~: resuelto, la semántica está invertida (§3.4). Toggle
  verificado: apaga, vuelve a encender y restaura escala y posición.
- **Extensión**: `gnome-extensions list --enabled | grep duo-swap` y probar
  `duo swap` con una ventana enfocada.
- **Mapeo táctil de `ELAN9009`** (touch y lápiz del ScreenPad) sobre `DP-1`:
  tocar el panel inferior y ver dónde aparece el puntero. Mutter suele
  resolverlo por EDID; si falla, corregir con
  `gsettings set org.gnome.desktop.peripherals.touchscreen:<ruta> output`.

### Opcional

- **Remapeo en el kernel vía hwdb** como alternativa al listener: declarar los
  scancodes en `/etc/udev/hwdb.d/61-zenbook-duo.hwdb` con
  `KEYBOARD_KEY_<scancode>=f20…f24` para dejarlos dentro del rango de XKB y
  asignables desde Configuración → Teclado. Más limpio, pero depende de que el
  scancode sea estable entre versiones de firmware.
- **Perfiles térmicos automáticos** según AC/batería (`platform_profile`).
- **PipeWire**: hacer persistente el `clock.force-quantum 512` del commit
  `b1a0e52` con un drop-in en `~/.config/pipewire/pipewire.conf.d/99-quantum.conf`
  en lugar de ejecutarlo tras cada arranque.

---

## 7. Estado de git

Todo el trabajo está en `main` (rama única): cuatro commits heredados del
upstream, `7499739` —que añade `ANALISIS-UX8402ZA.md` y `ux8402/`, integrado vía
PR #1— y la corrección de scancodes. El `duo.sh` y `setup.sh` originales se han
dejado intactos como referencia.
