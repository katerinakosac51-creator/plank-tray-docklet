//
// Copyright (C) 2024 Plank Reloaded Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank {

  /**
   * Manages global X11 keybindings for dock elements.
   * Grabs keys at the X11 level so they override all other bindings.
   */
  public class KeybindingManager : GLib.Object {

    private struct Binding {
      uint keycode;
      Gdk.ModifierType modifiers;
      unowned DockElement element;
    }

    private static KeybindingManager? instance = null;

    private Gee.ArrayList<Binding?> bindings;
    private Gdk.X11.Display? gdk_display = null;
    private unowned X.Display? display = null;
    private X.Window root_window;

    // Lock modifiers to ignore (Num Lock, Caps Lock, Scroll Lock)
    private const Gdk.ModifierType[] LOCK_MODS = {
      0,
      Gdk.ModifierType.MOD2_MASK, // Num Lock
      Gdk.ModifierType.LOCK_MASK, // Caps Lock
      Gdk.ModifierType.MOD2_MASK | Gdk.ModifierType.LOCK_MASK,
    };

    public static unowned KeybindingManager get_default () {
      if (instance == null)
        instance = new KeybindingManager ();
      return instance;
    }

    private KeybindingManager () {
      bindings = new Gee.ArrayList<Binding?> ();

      gdk_display = Gdk.Display.get_default () as Gdk.X11.Display;
      if (gdk_display == null) {
        warning ("KeybindingManager: Not running on X11, keybindings disabled");
        return;
      }

      display = gdk_display.get_xdisplay ();
      root_window = (Gdk.Screen.get_default ().get_root_window () as Gdk.X11.Window).get_xid ();

      // Install GDK event filter
      Gdk.Screen.get_default ().get_root_window ().add_filter (x11_event_filter);
    }

    ~KeybindingManager () {
      unbind_all ();
      if (gdk_display != null)
        Gdk.Screen.get_default ().get_root_window ().remove_filter (x11_event_filter);
    }

    /**
     * Bind a global keybinding to a dock element.
     * The accelerator string follows GTK format: "<Super>", "<Control><Alt>a", etc.
     *
     * @param accelerator the keybinding in GTK accelerator format
     * @param element the dock element to activate
     * @return true if binding was successful
     */
    public bool bind (string accelerator, DockElement element) {
      if (display == null) return false;
      if (accelerator == "") return false;

      uint keysym;
      Gdk.ModifierType modifiers;
      Gtk.accelerator_parse (accelerator, out keysym, out modifiers);

      if (keysym == 0 && modifiers == 0) {
        warning ("KeybindingManager: Failed to parse accelerator '%s'", accelerator);
        return false;
      }

      // Handle Super key as a standalone modifier
      // When the accelerator is just "<Super>", keysym will be 0 and modifiers will have SUPER
      // We need to grab Super_L key itself
      if (keysym == 0 && (modifiers & Gdk.ModifierType.SUPER_MASK) != 0) {
        keysym = Gdk.Key.Super_L;
        modifiers = modifiers & ~Gdk.ModifierType.SUPER_MASK;
      }

      var keycode = display.keysym_to_keycode (keysym);
      if (keycode == 0) {
        warning ("KeybindingManager: No keycode for keysym %u", keysym);
        return false;
      }

      // Remove any existing binding for this element
      unbind (element);

      Gdk.error_trap_push ();

      // Grab with all lock modifier combinations
      foreach (var lock_mod in LOCK_MODS) {
        display.grab_key ((int) keycode, (uint) (modifiers | lock_mod),
          root_window, false, X.GrabMode.Async, X.GrabMode.Async);
      }

      Gdk.error_trap_pop_ignored ();

      var binding = Binding () {
        keycode = keycode,
        modifiers = modifiers & Gtk.accelerator_get_default_mod_mask (),
        element = element
      };
      bindings.add (binding);

      debug ("KeybindingManager: Bound '%s' (keycode=%u, mods=%u) to %s",
        accelerator, keycode, modifiers, element.Text);

      return true;
    }

    /**
     * Remove the keybinding for a dock element.
     */
    public void unbind (DockElement element) {
      if (display == null) return;

      var to_remove = new Gee.ArrayList<Binding?> ();
      foreach (var binding in bindings) {
        if (binding.element == element) {
          Gdk.error_trap_push ();
          foreach (var lock_mod in LOCK_MODS) {
            display.ungrab_key ((int) binding.keycode, (uint) (binding.modifiers | lock_mod),
              root_window);
          }
          Gdk.error_trap_pop_ignored ();
          to_remove.add (binding);
        }
      }
      bindings.remove_all (to_remove);
    }

    /**
     * Remove all keybindings.
     */
    public void unbind_all () {
      if (display == null) return;

      Gdk.error_trap_push ();
      foreach (var binding in bindings) {
        foreach (var lock_mod in LOCK_MODS) {
          display.ungrab_key ((int) binding.keycode, (uint) (binding.modifiers | lock_mod),
            root_window);
        }
      }
      Gdk.error_trap_pop_ignored ();
      bindings.clear ();
    }

    private Gdk.FilterReturn x11_event_filter (Gdk.XEvent xevent, Gdk.Event event) {
      X.Event* xev = (X.Event*) xevent;

      if (xev->type != X.EventType.KeyPress)
        return Gdk.FilterReturn.CONTINUE;

      var key_event = (X.KeyEvent*) xev;
      var keycode = key_event->keycode;
      var state = key_event->state & Gtk.accelerator_get_default_mod_mask ();

      foreach (var binding in bindings) {
        if (binding.keycode == keycode &&
            binding.modifiers == (Gdk.ModifierType) state) {
          // Activate the element
          binding.element.clicked (PopupButton.LEFT, 0, (uint32) key_event->time);
          return Gdk.FilterReturn.REMOVE;
        }
      }

      return Gdk.FilterReturn.CONTINUE;
    }
  }
}
