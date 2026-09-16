#!/bin/bash
#
# duo-swap.sh - Mueve la ventana enfocada entre el panel principal y el ScreenPad.
#
# Delega en la extensión duo-swap@local porque bajo Wayland solo el compositor
# puede mover ventanas. Si la extensión no está activa, cae en el atajo nativo
# de mutter, que únicamente funciona si el usuario lo pulsa a mano.

set -uo pipefail

if gdbus call --session \
        --dest org.zenbook.Duo \
        --object-path /org/zenbook/Duo \
        --method org.zenbook.Duo.SwapMonitor >/dev/null 2>&1; then
    exit 0
fi

notify-send -a "Zenbook Duo" -t 4000 -i dialog-warning \
    "No se pudo mover la ventana" \
    "La extensión «duo-swap@local» no está activa.\nActívala con: gnome-extensions enable duo-swap@local" 2>/dev/null

echo "duo-swap: extensión duo-swap@local no disponible en el bus de sesión" >&2
exit 1
