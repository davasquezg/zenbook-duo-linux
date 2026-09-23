#!/usr/bin/env python3
"""
duo-keys.py - Listener de las teclas propias del Zenbook Duo UX8402ZA.

Motivo de existir: varias de las teclas del Duo emiten keycodes evdev por encima
de 255 (KEY_DISPLAYTOGGLE = 431, KEY_TOUCHPAD_TOGGLE = 530,
KEY_SELECTIVE_SCREENSHOT = 634...). XKB solo puede representar keycodes hasta
255, así que GNOME nunca las ve y no se pueden asignar con gsettings. La única
forma de recuperarlas es leer el dispositivo evdev directamente.

Requisitos: pertenencia al grupo 'input' (los nodos son root:input 0640).
No usa dependencias externas: decodifica struct input_event con 'struct'.

Uso:
    duo-keys.py            escucha y ejecuta las acciones configuradas
    duo-keys.py --scan     muestra los eventos de teclado para identificar teclas
    duo-keys.py --list     lista los dispositivos de entrada detectados
"""

import os
import re
import select
import shlex
import struct
import subprocess
import sys
import time

# struct input_event: __kernel_ulong_t tv_sec, tv_usec; __u16 type, code; __s32 value
EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_KEY = 0x01
EV_MSC = 0x04
MSC_SCAN = 0x04

# Dispositivos de los que nos interesa leer, por nombre exacto en
# /proc/bus/input/devices. "Asus WMI hotkeys" emite las teclas del Duo;
# el teclado AT se incluye porque algunas combinaciones Fn salen por ahí.
WATCHED_DEVICES = ("Asus WMI hotkeys", "AT Translated Set 2 keyboard")

def _config_dir():
    """Directorio de configuración del usuario real, incluso bajo sudo.

    El modo --scan necesita leer /dev/input, que exige root; sin esto la ruta
    sugerida al usuario sería /root/.config y la configuración se escribiría
    donde el servicio (que corre como el usuario) no la leería.
    """
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and os.geteuid() == 0:
        try:
            import pwd
            home = pwd.getpwnam(sudo_user).pw_dir
        except (ImportError, KeyError):
            home = os.path.expanduser("~")
        return os.path.join(home, ".config", "zenbook-duo")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "zenbook-duo")


CONF_DIR = _config_dir()
KEYS_CONF = os.path.join(CONF_DIR, "keys.conf")
HERE = os.path.dirname(os.path.realpath(__file__))

# Acciones predefinidas. El valor es el comando a ejecutar.
ACTIONS = {
    "screenpad": [os.path.join(HERE, "duo-ux8402.sh"), "screenpad", "toggle"],
    "swap": [os.path.join(HERE, "duo-swap.sh")],
    "menu": [os.path.join(HERE, "duo-menu.sh")],
}

# Mapeo por defecto por keycode. Solo se incluye lo confirmado en este equipo:
# las teclas de ScreenPad e intercambio llegan como KEY_UNKNOWN y deben mapearse
# por scancode en keys.conf (ver DEFAULT_SCAN_MAP y la salida de --scan).
DEFAULT_MAP = {
    148: "menu",        # KEY_PROG1 - Fn+F12 (ScreenXpert/MyASUS en Windows)
}

# Mapeo por defecto por scancode, para las teclas que el driver no reconoce.
# Confirmados por captura en un UX8402ZA (BIOS 306); ninguno de los dos figura
# en el keymap de asus-nb-wmi, por eso ambos llegan como KEY_UNKNOWN (240).
DEFAULT_SCAN_MAP = {
    0x6A: "screenpad",   # apagar / encender el ScreenPad Plus
    0x9C: "swap",        # intercambiar ventana entre panel principal e inferior
}

DEBOUNCE_SECONDS = 0.35


def log(msg):
    print(f"{time.strftime('%F %T')} - KEYS - {msg}", flush=True)


def keycode_names():
    """Mapa keycode -> nombre simbólico, leído de las cabeceras del kernel."""
    names = {}
    header = "/usr/include/linux/input-event-codes.h"
    try:
        with open(header) as fh:
            for line in fh:
                m = re.match(r"#define\s+(KEY_\w+)\s+(0x[0-9a-fA-F]+|\d+)", line)
                if m:
                    names.setdefault(int(m.group(2), 0), m.group(1))
    except OSError:
        pass
    return names


def find_devices():
    """Devuelve [(nombre, /dev/input/eventN)] para los dispositivos vigilados."""
    found = []
    try:
        with open("/proc/bus/input/devices") as fh:
            blocks = fh.read().split("\n\n")
    except OSError as exc:
        log(f"ERROR - no se puede leer /proc/bus/input/devices: {exc}")
        return found

    for block in blocks:
        name = re.search(r'N: Name="([^"]*)"', block)
        handlers = re.search(r"H: Handlers=(.*)", block)
        if not name or not handlers:
            continue
        if name.group(1) not in WATCHED_DEVICES:
            continue
        for token in handlers.group(1).split():
            if token.startswith("event"):
                found.append((name.group(1), f"/dev/input/{token}"))
                break
    return found


def load_map():
    """Lee keys.conf y devuelve (mapa_por_keycode, mapa_por_scancode).

    Formato de cada línea:
        148       = menu        keycode evdev (forma abreviada)
        key:148   = menu        keycode evdev (forma explícita)
        scan:0x38 = screenpad   scancode crudo, para las teclas KEY_UNKNOWN
    Una acción vacía desactiva esa tecla.
    """
    by_key = dict(DEFAULT_MAP)
    by_scan = dict(DEFAULT_SCAN_MAP)
    if not os.path.exists(KEYS_CONF):
        return by_key, by_scan

    with open(KEYS_CONF) as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            code, action = (part.strip() for part in line.split("=", 1))

            target = by_key
            if code.lower().startswith("scan:"):
                target, code = by_scan, code[5:].strip()
            elif code.lower().startswith("key:"):
                code = code[4:].strip()

            try:
                code = int(code, 0)       # base 0: admite 148 y 0x38
            except ValueError:
                log(f"ERROR - código inválido en keys.conf: {code!r}")
                continue

            if action:
                target[code] = action
            else:
                target.pop(code, None)
    return by_key, by_scan


def open_devices():
    devices = find_devices()
    if not devices:
        log("ERROR - no se encontró ningún dispositivo de entrada vigilado")
        return {}
    fds = {}
    for name, path in devices:
        try:
            fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = (name, path)
            log(f"escuchando {name} en {path}")
        except PermissionError:
            log(f"ERROR - sin permiso sobre {path}: añade tu usuario al grupo 'input' "
                f"(sudo usermod -aG input $USER) y reinicia el equipo")
        except OSError as exc:
            log(f"ERROR - no se puede abrir {path}: {exc}")
    return fds


def run_action(action):
    cmd = ACTIONS.get(action)
    if cmd is None:
        # Cualquier otra cosa en keys.conf se trata como un comando literal
        cmd = shlex.split(action)
    if not cmd:
        return
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        log(f"acción: {action}")
    except OSError as exc:
        log(f"ERROR - no se pudo ejecutar {action!r}: {exc}")


def loop(scan=False):
    fds = open_devices()
    if not fds:
        return 1
    by_key, by_scan = ({}, {}) if scan else load_map()
    names = keycode_names()

    if scan:
        print("\nPulsa cada tecla que quieras identificar, de una en una.")
        print("Copia la línea 'keys.conf:' correspondiente en "
              f"{KEYS_CONF}.\nCtrl+C para salir.\n")
    else:
        for code, action in sorted(by_key.items()):
            log(f"mapeo keycode {code} ({names.get(code, '?')}) -> {action}")
        for code, action in sorted(by_scan.items()):
            log(f"mapeo scancode 0x{code:X} -> {action}")
        if not by_key and not by_scan:
            log("aviso - no hay ninguna tecla mapeada; ejecuta con --scan")

    last_fired = {}
    pending_scan = {}      # último MSC_SCAN visto por dispositivo
    try:
        while True:
            ready, _, _ = select.select(list(fds), [], [], None)
            for fd in ready:
                try:
                    data = os.read(fd, EVENT_SIZE * 64)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    log(f"ERROR - lectura de {fds[fd][1]}: {exc}")
                    os.close(fd)
                    del fds[fd]
                    if not fds:
                        return 1
                    continue

                for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _, _, etype, code, value = struct.unpack(
                        EVENT_FORMAT, data[offset:offset + EVENT_SIZE]
                    )

                    # El driver envía el scancode crudo inmediatamente antes del
                    # EV_KEY. Es la única forma de distinguir las teclas que
                    # llegan todas como KEY_UNKNOWN.
                    if etype == EV_MSC and code == MSC_SCAN:
                        pending_scan[fd] = value & 0xFFFFFFFF
                        continue

                    if etype != EV_KEY or value != 1:    # solo pulsaciones
                        continue

                    scancode = pending_scan.pop(fd, None)

                    if scan:
                        report(code, scancode, names, fds[fd][0])
                        continue

                    action = None
                    ident = None
                    # El scancode tiene prioridad: es más específico que un
                    # keycode que puede estar compartido por varias teclas.
                    if scancode is not None and scancode in by_scan:
                        action, ident = by_scan[scancode], ("scan", scancode)
                    elif code in by_key:
                        action, ident = by_key[code], ("key", code)
                    if not action:
                        continue

                    now = time.monotonic()
                    if now - last_fired.get(ident, 0.0) < DEBOUNCE_SECONDS:
                        continue
                    last_fired[ident] = now
                    run_action(action)
    except KeyboardInterrupt:
        print()
    finally:
        for fd in fds:
            os.close(fd)
    return 0


def report(keycode, scancode, names, device):
    """Imprime una tecla detectada y la línea de keys.conf que le corresponde."""
    name = names.get(keycode, "sin nombre")
    scan_txt = f"0x{scancode:X}" if scancode is not None else "-"
    print(f"  keycode {keycode:<5} scancode {scan_txt:<10} {name:<24} [{device}]")

    # KEY_UNKNOWN (240) lo emite el driver para scancodes que no tiene en su
    # keymap; varias teclas distintas comparten ese keycode, así que la única
    # referencia fiable es el scancode.
    if keycode == 240 and scancode is not None:
        print(f"      keys.conf:  scan:0x{scancode:X} = <acción>"
              "      (tecla no reconocida por el driver)")
    elif keycode > 255:
        print(f"      keys.conf:  key:{keycode} = <acción>"
              "      (fuera del rango de XKB: GNOME no puede verla)")
    else:
        print(f"      keys.conf:  key:{keycode} = <acción>")
    print(flush=True)


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--list":
        for name, path in find_devices():
            print(f"{path}\t{name}")
        return 0
    if arg in ("-h", "--help"):
        print(__doc__)
        return 0
    return loop(scan=(arg == "--scan"))


if __name__ == "__main__":
    sys.exit(main())
