#!/bin/bash
#
# duo-ux8402.sh - Gestión del ASUS Zenbook Pro 14 Duo OLED (UX8402ZA) en Linux
#
# Sustituye a duo.sh del upstream, que está escrito para el UX8406 (teclado
# Bluetooth desmontable y dos paneles eDP). En el UX8402ZA:
#   - el ScreenPad Plus es DP-1, no eDP-2
#   - su backlight es /sys/class/backlight/asus_screenpad (0-255)
#   - el backlight del teclado es /sys/class/leds/asus::kbd_backlight (0-3)
#   - no hay teclado desmontable ni acelerómetro
#
# No usa sudo: depende de la regla udev 99-zenbook-duo-ux8402.rules y de que el
# usuario pertenezca al grupo 'video'.

set -uo pipefail

# ---------------------------------------------------------------- configuración

CONF_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/zenbook-duo"
CONF_FILE="${CONF_DIR}/duo.conf"

# Valores por defecto; se sobreescriben desde ${CONF_FILE}
DEFAULT_KB_BACKLIGHT=1     # 0-3, nivel restaurado en arranque y al despertar
SYNC_BRIGHTNESS=true       # replicar el brillo del panel principal en el ScreenPad
SCREENPAD_DIM=85           # % del brillo principal aplicado al ScreenPad
SCREENPAD_MIN=5            # brillo mínimo del ScreenPad mientras esté encendido
SCREENPAD_OFF_ON_LID=true  # apagar el ScreenPad al cerrar la tapa
SCREENPAD_OFF_ON_BATTERY=false

[ -r "${CONF_FILE}" ] && . "${CONF_FILE}"

# ------------------------------------------------------------------ rutas sysfs

SP_DIR=/sys/class/backlight/asus_screenpad
MAIN_DIR=/sys/class/backlight/intel_backlight
KBD_LED=/sys/class/leds/asus::kbd_backlight
SP_CONNECTOR=DP-1
MAIN_CONNECTOR=eDP-1

RUN_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/zenbook-duo"
STATE_FILE="${RUN_DIR}/state"
LOG_FILE="${RUN_DIR}/duo.log"

mkdir -p "${RUN_DIR}" "${CONF_DIR}"

log() { printf '%s - %s\n' "$(date '+%F %T')" "$*" >> "${LOG_FILE}"; }

notify() {
    command -v notify-send >/dev/null || return 0
    notify-send -a "Zenbook Duo" -t 1500 --hint=int:transient:1 \
        -i preferences-desktop-display "$1" "${2:-}" 2>/dev/null
}

# Lee una clave del archivo de estado (formato clave=valor, sin `source`)
state_get() {
    [ -r "${STATE_FILE}" ] || return 1
    local v
    v=$(grep -m1 "^${1}=" "${STATE_FILE}" 2>/dev/null) || return 1
    printf '%s' "${v#*=}"
}

state_set() {
    local key="$1" val="$2" tmp="${STATE_FILE}.tmp"
    touch "${STATE_FILE}"
    grep -v "^${key}=" "${STATE_FILE}" > "${tmp}" 2>/dev/null
    printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
    mv -f "${tmp}" "${STATE_FILE}"
}

# Escribe en sysfs; si no hay permiso directo, lo intenta vía pkexec una sola vez
sysfs_write() {
    local path="$1" val="$2"
    if [ -w "${path}" ]; then
        printf '%s' "${val}" > "${path}" 2>/dev/null && return 0
    fi
    log "ERROR - sin permiso de escritura en ${path} (¿falta la regla udev o el grupo 'video'?)"
    return 1
}

# --------------------------------------------------------- backlight del teclado

# duo_kb_backlight [0-3]  -- sin argumento, muestra el nivel actual
duo_kb_backlight() {
    [ -e "${KBD_LED}/brightness" ] || { log "ERROR - ${KBD_LED} no existe"; return 1; }
    if [ $# -eq 0 ]; then
        cat "${KBD_LED}/brightness"
        return 0
    fi
    local level="$1" max
    max=$(cat "${KBD_LED}/max_brightness" 2>/dev/null || echo 3)
    [[ "${level}" =~ ^[0-9]+$ ]] || { log "ERROR - nivel inválido: ${level}"; return 1; }
    (( level > max )) && level=${max}
    sysfs_write "${KBD_LED}/brightness" "${level}" &&
        log "KEYBOARD - backlight = ${level}"
}

# ------------------------------------------------------------------- ScreenPad

sp_max()     { cat "${SP_DIR}/max_brightness" 2>/dev/null || echo 255; }
sp_current() { cat "${SP_DIR}/actual_brightness" 2>/dev/null || echo 0; }

# El driver puede dejar valores fuera de rango en `brightness`; se normalizan.
sp_sanitize() {
    local cur max
    cur=$(cat "${SP_DIR}/brightness" 2>/dev/null || echo 0)
    max=$(sp_max)
    if ! [[ "${cur}" =~ ^[0-9]+$ ]] || (( cur > max )); then
        log "SCREENPAD - valor fuera de rango (${cur}), normalizando a $(sp_current)"
        sysfs_write "${SP_DIR}/brightness" "$(sp_current)"
    fi
}

# ¿Está encendido el ScreenPad? bl_power: 0 = encendido, 1 = apagado
sp_is_on() {
    local p
    p=$(cat "${SP_DIR}/bl_power" 2>/dev/null || echo 0)
    [ "${p}" = "0" ] && (( $(sp_current) > 0 ))
}

duo_screenpad() {
    [ -e "${SP_DIR}/bl_power" ] || { log "ERROR - ${SP_DIR} no existe"; return 1; }
    local action="${1:-toggle}"

    if [ "${action}" = toggle ]; then
        sp_is_on && action=off || action=on
    fi

    case "${action}" in
    off)
        # Se guarda el nivel para poder restaurarlo
        local cur; cur=$(sp_current)
        (( cur > 0 )) && state_set SP_LAST "${cur}"
        sysfs_write "${SP_DIR}/brightness" 0
        sysfs_write "${SP_DIR}/bl_power" 1
        log "SCREENPAD - apagado (nivel guardado: ${cur})"
        notify "ScreenPad apagado"
        ;;
    on)
        local last; last=$(state_get SP_LAST || echo "")
        [[ "${last}" =~ ^[0-9]+$ ]] && (( last > 0 )) || last=$(( $(sp_max) * 60 / 100 ))
        sysfs_write "${SP_DIR}/bl_power" 0
        sysfs_write "${SP_DIR}/brightness" "${last}"
        log "SCREENPAD - encendido (nivel ${last})"
        notify "ScreenPad encendido"
        ;;
    status)
        sp_is_on && echo "on ($(sp_current)/$(sp_max))" || echo "off"
        ;;
    *)
        # Valor numérico directo: fija el brillo
        if [[ "${action}" =~ ^[0-9]+$ ]]; then
            local max; max=$(sp_max)
            (( action > max )) && action=${max}
            sysfs_write "${SP_DIR}/bl_power" 0
            sysfs_write "${SP_DIR}/brightness" "${action}"
            log "SCREENPAD - brillo = ${action}"
        else
            echo "uso: duo screenpad {on|off|toggle|status|0-$(sp_max)}" >&2
            return 1
        fi
        ;;
    esac
}

# ---------------------------------------------- sincronía de brillo principal→SP

sync_brightness_once() {
    [ "${SYNC_BRIGHTNESS}" = true ] || return 0
    sp_is_on || return 0     # no reactivar un ScreenPad apagado a propósito

    local cur main_max sp_max_v target
    cur=$(cat "${MAIN_DIR}/brightness" 2>/dev/null) || return 0
    main_max=$(cat "${MAIN_DIR}/max_brightness" 2>/dev/null || echo 400)
    sp_max_v=$(sp_max)
    (( main_max > 0 )) || return 0

    # Reescalado 0-main_max -> 0-sp_max con atenuación configurable
    target=$(( cur * sp_max_v / main_max * SCREENPAD_DIM / 100 ))
    (( target < SCREENPAD_MIN )) && target=${SCREENPAD_MIN}
    (( target > sp_max_v ))      && target=${sp_max_v}

    [ "${target}" = "$(sp_current)" ] && return 0
    sysfs_write "${SP_DIR}/brightness" "${target}"
    log "BRIGHTNESS - principal ${cur}/${main_max} -> ScreenPad ${target}/${sp_max_v}"
}

watch_brightness() {
    command -v inotifywait >/dev/null || { log "ERROR - falta inotify-tools"; return 1; }
    log "BRIGHTNESS - vigilando ${MAIN_DIR}/brightness"
    while true; do
        inotifywait -qq -e modify "${MAIN_DIR}/brightness" 2>/dev/null
        sync_brightness_once
    done
}

# ------------------------------------------------------------ tapa y alimentación

on_ac() {
    local s
    for s in /sys/class/power_supply/A{C,DP}*/online; do
        [ -r "${s}" ] && [ "$(cat "${s}")" = "1" ] && return 0
    done
    return 1
}

watch_lid() {
    [ "${SCREENPAD_OFF_ON_LID}" = true ] || return 0
    local lid=/proc/acpi/button/lid/LID0/state
    [ -r "${lid}" ] || return 0
    log "LID - vigilando estado de la tapa"
    local prev="" now
    while true; do
        now=$(awk '{print $2}' "${lid}" 2>/dev/null)
        if [ -n "${now}" ] && [ "${now}" != "${prev}" ]; then
            prev="${now}"
            [ "${now}" = closed ] && duo_screenpad off
        fi
        sleep 2
    done
}

# ------------------------------------------------------------------ ciclo de vida

duo_restore() {
    sp_sanitize
    duo_kb_backlight "${DEFAULT_KB_BACKLIGHT}"
    if [ "${SCREENPAD_OFF_ON_BATTERY}" = true ] && ! on_ac; then
        duo_screenpad off
    else
        sync_brightness_once
    fi
}

daemon() {
    log "DAEMON - inicio (PID $$)"
    trap 'log "DAEMON - parada"; pkill -P $$; exit 0' INT TERM

    duo_restore

    watch_brightness &
    watch_lid &

    # Listener de las teclas propias del Duo (ScreenPad / swap / launcher)
    local keys="$(dirname "$(readlink -f "$0")")/duo-keys.py"
    if [ -x "${keys}" ]; then
        "${keys}" >> "${LOG_FILE}" 2>&1 &
    else
        log "KEYS - duo-keys.py no encontrado en ${keys}"
    fi

    wait
}

# ------------------------------------------------------------------------- CLI

usage() {
    cat <<'USAGE'
uso: duo <comando> [args]

  daemon                      ejecuta los watchers (lo invoca el servicio systemd)
  screenpad on|off|toggle     enciende, apaga o alterna el ScreenPad Plus
  screenpad status            estado actual
  screenpad <0-255>           fija el brillo del ScreenPad
  kbd [0-3]                   consulta o fija el backlight del teclado
  sync                        sincroniza el brillo principal -> ScreenPad una vez
  swap                        mueve la ventana enfocada al otro monitor
  menu                        abre el panel de control del Duo
  boot|post|thaw              restaura estado (arranque / resume)
  pre|suspend|hibernate       prepara para suspensión
  status                      volcado de estado del hardware
USAGE
}

main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift

    case "${cmd}" in
    daemon|"")      daemon ;;
    screenpad|sp)   duo_screenpad "${1:-toggle}" ;;
    kbd|kbb)        duo_kb_backlight "$@" ;;
    sync)           sync_brightness_once ;;
    swap)           "$(dirname "$(readlink -f "$0")")/duo-swap.sh" ;;
    menu)           "$(dirname "$(readlink -f "$0")")/duo-menu.sh" ;;
    boot|post|thaw|resume)
                    log "ACPI - ${cmd}"; duo_restore ;;
    pre|suspend|hibernate|shutdown)
                    log "ACPI - ${cmd}"; duo_kb_backlight 0 ;;
    status)
        echo "ScreenPad : $(duo_screenpad status)"
        echo "  bl_power: $(cat "${SP_DIR}/bl_power" 2>/dev/null)"
        echo "  brillo  : $(sp_current)/$(sp_max)"
        echo "Teclado   : $(duo_kb_backlight)/$(cat "${KBD_LED}/max_brightness" 2>/dev/null)"
        echo "Principal : $(cat "${MAIN_DIR}/brightness" 2>/dev/null)/$(cat "${MAIN_DIR}/max_brightness" 2>/dev/null)"
        echo "Alimentac.: $(on_ac && echo AC || echo batería)"
        echo "Conectores: ${MAIN_CONNECTOR} + ${SP_CONNECTOR}"
        ;;
    -h|--help|help) usage ;;
    *)              echo "comando desconocido: ${cmd}" >&2; usage; return 1 ;;
    esac
}

# systemd-sleep invoca el script como: duo pre|post suspend|hibernate
if [ "$(basename "$0")" = duo ] && [ "${1:-}" = pre -o "${1:-}" = post ]; then
    main "${1}"
else
    main "$@"
fi
