#!/bin/bash
#
# duo-menu.sh - Panel de control del Zenbook Duo.
#
# Equivalente funcional de ScreenXpert/MyASUS (la tecla Fn+F12 en Windows):
# reúne en un diálogo las acciones del hardware propio del Duo que no tienen
# interfaz en GNOME.

set -uo pipefail

DUO="$(dirname "$(readlink -f "$0")")/duo-ux8402.sh"
SP_DIR=/sys/class/backlight/asus_screenpad
KBD_LED=/sys/class/leds/asus::kbd_backlight

command -v zenity >/dev/null || {
    notify-send -a "Zenbook Duo" "Falta zenity" "sudo apt install zenity" 2>/dev/null
    exit 1
}

sp_state=$("${DUO}" screenpad status 2>/dev/null || echo "?")
kb_state=$(cat "${KBD_LED}/brightness" 2>/dev/null || echo "?")
profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo "?")

CHOICE=$(zenity --list \
    --title="Zenbook Duo" \
    --text="ScreenPad: <b>${sp_state}</b>   ·   Teclado: <b>${kb_state}/3</b>   ·   Perfil: <b>${profile}</b>" \
    --column="Acción" --column="Descripción" \
    --width=520 --height=380 --hide-header \
    "screenpad"  "Encender / apagar el ScreenPad Plus" \
    "swap"       "Mover la ventana actual al otro monitor" \
    "sp-brillo"  "Ajustar el brillo del ScreenPad" \
    "kbd"        "Ajustar el backlight del teclado" \
    "perfil"     "Cambiar el perfil de rendimiento" \
    "displays"   "Abrir la configuración de pantallas" \
    2>/dev/null) || exit 0

case "${CHOICE}" in
screenpad)
    "${DUO}" screenpad toggle
    ;;
swap)
    "$(dirname "${DUO}")/duo-swap.sh"
    ;;
sp-brillo)
    MAX=$(cat "${SP_DIR}/max_brightness" 2>/dev/null || echo 255)
    CUR=$(cat "${SP_DIR}/actual_brightness" 2>/dev/null || echo 0)
    VAL=$(zenity --scale --title="Brillo del ScreenPad" --text="Nivel (0-${MAX})" \
        --min-value=0 --max-value="${MAX}" --value="${CUR}" --step=5 2>/dev/null) || exit 0
    "${DUO}" screenpad "${VAL}"
    ;;
kbd)
    VAL=$(zenity --scale --title="Backlight del teclado" --text="Nivel (0-3)" \
        --min-value=0 --max-value=3 --value="${kb_state}" --step=1 2>/dev/null) || exit 0
    "${DUO}" kbd "${VAL}"
    ;;
perfil)
    CHOICES=$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null) || exit 1
    SEL=$(zenity --list --title="Perfil de rendimiento" --text="Selecciona un perfil" \
        --column="Perfil" ${CHOICES} --width=320 --height=260 2>/dev/null) || exit 0
    if ! echo "${SEL}" > /sys/firmware/acpi/platform_profile 2>/dev/null; then
        pkexec tee /sys/firmware/acpi/platform_profile <<< "${SEL}" >/dev/null
    fi
    ;;
displays)
    gnome-control-center display &
    ;;
esac
