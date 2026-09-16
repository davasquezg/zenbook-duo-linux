/*
 * Zenbook Duo - Swap monitor
 *
 * En Wayland ningún proceso externo puede mover una ventana: solo el
 * compositor conoce y manipula su geometría (org.gnome.Shell.Introspect
 * deniega GetWindows a clientes no privilegiados, y Eval está deshabilitado
 * en builds de producción). Esta extensión expone un único método D-Bus que
 * mueve la ventana enfocada al siguiente monitor, que es lo que replica la
 * tecla de intercambio del Duo bajo Windows.
 */

import Gio from 'gi://Gio';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'org.zenbook.Duo';
const OBJECT_PATH = '/org/zenbook/Duo';

const IFACE = `
<node>
  <interface name="org.zenbook.Duo">
    <method name="SwapMonitor">
      <arg type="b" direction="out" name="moved"/>
    </method>
    <method name="MoveToMonitor">
      <arg type="i" direction="in" name="index"/>
      <arg type="b" direction="out" name="moved"/>
    </method>
  </interface>
</node>`;

export default class DuoSwapExtension extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.bus_own_name(
            Gio.BusType.SESSION,
            BUS_NAME,
            Gio.BusNameOwnerFlags.NONE,
            null, null, null
        );
    }

    disable() {
        if (this._nameId) {
            Gio.bus_unown_name(this._nameId);
            this._nameId = null;
        }
        if (this._dbus) {
            this._dbus.unexport();
            this._dbus = null;
        }
    }

    _move(window, index) {
        // move_to_monitor no restaura el estado maximizado en el destino, así
        // que se desmaximiza y se vuelve a maximizar si procede.
        const maximized = window.get_maximized();
        if (maximized)
            window.unmaximize(maximized);

        window.move_to_monitor(index);

        if (maximized)
            window.maximize(maximized);

        window.activate(global.get_current_time());
        return true;
    }

    SwapMonitor() {
        const window = global.display.get_focus_window();
        if (!window || window.is_override_redirect())
            return false;

        const count = global.display.get_n_monitors();
        if (count < 2)
            return false;

        return this._move(window, (window.get_monitor() + 1) % count);
    }

    MoveToMonitor(index) {
        const window = global.display.get_focus_window();
        if (!window || window.is_override_redirect())
            return false;
        if (index < 0 || index >= global.display.get_n_monitors())
            return false;

        return this._move(window, index);
    }
}
