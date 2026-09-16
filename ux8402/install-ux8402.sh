#!/bin/bash
#
# install-ux8402.sh - Instalador para ASUS Zenbook Pro 14 Duo OLED (UX8402ZA)
#
# Retira la instalación del duo.sh original (pensado para el UX8406) e instala
# la variante específica de este modelo.
#
#   ./install-ux8402.sh              instala
#   ./install-ux8402.sh --uninstall  desinstala
#   ./install-ux8402.sh --purge-old  solo retira la instalación anterior

set -euo pipefail

LIB_DIR=/usr/local/lib/zenbook-duo
BIN_LINK=/usr/local/bin/duo
UDEV_RULE=/etc/udev/rules.d/99-zenbook-duo-ux8402.rules
SLEEP_HOOK=/lib/systemd/system-sleep/zenbook-duo
USER_UNIT="${HOME}/.config/systemd/user/zenbook-duo.service"
EXT_UUID="duo-swap@local"
EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${EXT_UUID}"
CONF_DIR="${HOME}/.config/zenbook-duo"
SRC_DIR="$(dirname "$(readlink -f "$0")")"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

check_model() {
    local model
    model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo desconocido)
    case "${model}" in
    *UX8402*) say "Modelo detectado: ${model}" ;;
    *)
        warn "Este instalador es para el UX8402; se ha detectado: ${model}"
        read -rp "¿Continuar de todos modos? [s/N] " answer
        [[ "${answer}" =~ ^[sSyY]$ ]] || exit 1
        ;;
    esac
}

purge_old() {
    say "Retirando la instalación anterior (duo.sh del upstream)"

    systemctl --user disable --now zenbook-duo-user.service 2>/dev/null || true
    sudo systemctl disable --now zenbook-duo.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/zenbook-duo.service
    sudo rm -f /etc/systemd/user/zenbook-duo-user.service
    sudo rm -f /lib/systemd/system-sleep/duo
    sudo rm -f /usr/local/bin/duo.orig
    rm -rf /tmp/duo

    # Las dos entradas NOPASSWD del setup.sh original: la de /tmp/duo/backlight.py
    # concede root sobre un fichero en una ruta escribible por el usuario.
    if sudo grep -qE '/tmp/duo/backlight\.py|card1-eDP-2-backlight' /etc/sudoers 2>/dev/null; then
        say "Eliminando entradas inseguras de /etc/sudoers"
        sudo cp /etc/sudoers "/etc/sudoers.bak.$(date +%Y%m%d%H%M%S)"
        sudo sed -i -E '/\/tmp\/duo\/backlight\.py/d; /card1-eDP-2-backlight/d' /etc/sudoers
        sudo visudo -c >/dev/null || {
            warn "sudoers quedó inválido; restaurando copia de seguridad"
            sudo cp "$(ls -t /etc/sudoers.bak.* | head -1)" /etc/sudoers
            exit 1
        }
    fi

    sudo systemctl daemon-reload
    systemctl --user daemon-reload 2>/dev/null || true
}

install_deps() {
    local missing=()
    for pkg in inotify-tools zenity; do
        dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
    done
    if ((${#missing[@]})); then
        say "Instalando dependencias: ${missing[*]}"
        sudo apt-get install -y "${missing[@]}"
    fi
}

install_files() {
    say "Instalando scripts en ${LIB_DIR}"
    sudo mkdir -p "${LIB_DIR}"
    sudo install -m 0755 "${SRC_DIR}/duo-ux8402.sh" "${LIB_DIR}/duo-ux8402.sh"
    sudo install -m 0755 "${SRC_DIR}/duo-keys.py"   "${LIB_DIR}/duo-keys.py"
    sudo install -m 0755 "${SRC_DIR}/duo-swap.sh"   "${LIB_DIR}/duo-swap.sh"
    sudo install -m 0755 "${SRC_DIR}/duo-menu.sh"   "${LIB_DIR}/duo-menu.sh"
    sudo ln -sf "${LIB_DIR}/duo-ux8402.sh" "${BIN_LINK}"
}

install_udev() {
    say "Instalando regla udev y ajustando grupos"
    sudo install -m 0644 "${SRC_DIR}/99-zenbook-duo-ux8402.rules" "${UDEV_RULE}"
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=backlight --subsystem-match=leds

    # 'video' para backlight del ScreenPad y del teclado; 'input' para leer las
    # teclas del Duo, cuyos keycodes exceden lo que XKB puede representar.
    local relogin=false
    for grp in video input; do
        if ! id -nG "${USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
            sudo usermod -aG "${grp}" "${USER}"
            relogin=true
        fi
    done
    ${relogin} && warn "Se han añadido grupos nuevos: cierra la sesión y vuelve a entrar."
    return 0
}

install_services() {
    say "Instalando servicio de usuario y gancho de suspensión"

    mkdir -p "$(dirname "${USER_UNIT}")"
    cat > "${USER_UNIT}" <<UNIT
[Unit]
Description=Zenbook Duo UX8402ZA
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=${LIB_DIR}/duo-ux8402.sh daemon
ExecStopPost=${LIB_DIR}/duo-ux8402.sh kbd 0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT

    # El gancho de systemd-sleep corre como root: restaura el estado al despertar.
    sudo tee "${SLEEP_HOOK}" >/dev/null <<HOOK
#!/bin/bash
# Restaura el backlight del Zenbook Duo tras suspender o hibernar.
case "\$1" in
    pre)  ${LIB_DIR}/duo-ux8402.sh pre  ;;
    post) ${LIB_DIR}/duo-ux8402.sh post ;;
esac
HOOK
    sudo chmod 0755 "${SLEEP_HOOK}"

    systemctl --user daemon-reload
    systemctl --user enable --now zenbook-duo.service
}

install_extension() {
    say "Instalando la extensión GNOME ${EXT_UUID}"
    mkdir -p "${EXT_DIR}"
    cp -r "${SRC_DIR}/gnome-extension/${EXT_UUID}/." "${EXT_DIR}/"

    if gnome-extensions enable "${EXT_UUID}" 2>/dev/null; then
        say "Extensión activada"
    else
        warn "No se pudo activar la extensión todavía."
        warn "Tras reiniciar la sesión, ejecuta: gnome-extensions enable ${EXT_UUID}"
    fi
}

install_config() {
    mkdir -p "${CONF_DIR}"
    if [ ! -f "${CONF_DIR}/duo.conf" ]; then
        say "Creando ${CONF_DIR}/duo.conf"
        cat > "${CONF_DIR}/duo.conf" <<CONF
# Configuración del Zenbook Duo UX8402ZA

DEFAULT_KB_BACKLIGHT=1       # backlight del teclado al arrancar y al despertar (0-3)
SYNC_BRIGHTNESS=true         # replicar el brillo del panel principal en el ScreenPad
SCREENPAD_DIM=85             # % del brillo principal aplicado al ScreenPad
SCREENPAD_MIN=5              # brillo mínimo del ScreenPad mientras esté encendido
SCREENPAD_OFF_ON_LID=true    # apagar el ScreenPad al cerrar la tapa
SCREENPAD_OFF_ON_BATTERY=false
CONF
    fi
    if [ ! -f "${CONF_DIR}/keys.conf" ]; then
        say "Creando ${CONF_DIR}/keys.conf"
        cat > "${CONF_DIR}/keys.conf" <<CONF
# Asignación de las teclas propias del Duo.
#
#   key:148   = menu        por keycode evdev
#   scan:0x38 = screenpad   por scancode crudo
#   148       = menu        forma abreviada, equivale a key:148
#
# Las teclas de ScreenPad e intercambio llegan como KEY_UNKNOWN (240) porque el
# driver asus-nb-wmi no tiene su scancode en el keymap; como varias comparten ese
# keycode, hay que mapearlas por scancode.
#
# Para averiguar los códigos de una tecla, ejecuta y púlsala:
#     ${LIB_DIR}/duo-keys.py --scan
# Deja la acción vacía para desactivar una tecla.
#
# Acciones: screenpad | swap | menu | <cualquier comando literal>

key:148   = menu        # KEY_PROG1 - Fn+F12, panel de control

# Scancodes confirmados en un UX8402ZA con BIOS 306. Si en tu equipo están
# cruzados, intercambia las dos acciones.
scan:0x9C = screenpad   # apagar / encender el ScreenPad Plus
scan:0x6A = swap        # mover la ventana enfocada al otro monitor

# KEY_TOUCHPAD_TOGGLE (530) también queda fuera del rango de XKB; si quieres
# reutilizar esa tecla, descomenta:
# key:530 = menu
CONF
    fi
}

uninstall() {
    say "Desinstalando"
    systemctl --user disable --now zenbook-duo.service 2>/dev/null || true
    rm -f "${USER_UNIT}"
    systemctl --user daemon-reload 2>/dev/null || true
    sudo rm -f "${SLEEP_HOOK}" "${UDEV_RULE}" "${BIN_LINK}"
    sudo rm -rf "${LIB_DIR}"
    sudo udevadm control --reload-rules
    gnome-extensions disable "${EXT_UUID}" 2>/dev/null || true
    rm -rf "${EXT_DIR}"
    say "Hecho. La configuración en ${CONF_DIR} se conserva."
}

case "${1:-}" in
--uninstall) uninstall; exit 0 ;;
--purge-old) purge_old; exit 0 ;;
"") ;;
*) echo "uso: $0 [--uninstall|--purge-old]" >&2; exit 1 ;;
esac

check_model
purge_old
install_deps
install_files
install_udev
install_config
install_services
install_extension

say "Instalación completa."
echo
echo "  Comprobar estado : duo status"
echo "  Alternar ScreenPad: duo screenpad toggle"
echo "  Identificar teclas: ${LIB_DIR}/duo-keys.py --scan"
echo "  Registro         : \${XDG_RUNTIME_DIR}/zenbook-duo/duo.log"
echo
warn "Cierra la sesión y vuelve a entrar para que surtan efecto los grupos"
warn "'video' e 'input' y para que cargue la extensión de GNOME."
