//
// Copyright (C) 2026 Plank Reloaded Developers
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

using Plank;

[DBus (name = "org.kde.StatusNotifierItem")]
interface StatusNotifierItemProxy : Object {
  public abstract string title { owned get; }
  public abstract string icon_name { owned get; }
  public abstract string id { owned get; }
  public abstract string status { owned get; }
  [DBus (name = "IconThemePath")]
  public abstract string icon_theme_path { owned get; }
  public abstract void activate (int x, int y) throws Error;
  public abstract void secondary_activate (int x, int y) throws Error;
}

[DBus (name = "org.freedesktop.DBus")]
interface FreedesktopDBus : Object {
  [DBus (name = "GetConnectionUnixProcessID")]
  public abstract uint32 get_connection_unix_process_id (string bus_name) throws Error;
  public abstract string[] list_names () throws Error;
}

// Our own implementation of the StatusNotifierWatcher
[DBus (name = "org.kde.StatusNotifierWatcher")]
class StatusNotifierWatcherImpl : Object {
  private Gee.ArrayList<string> items;
  private unowned Docky.TrayDockItem dock_item;

  public signal void status_notifier_item_registered (string service);
  public signal void status_notifier_item_unregistered (string service);
  public signal void status_notifier_host_registered ();

  public bool is_status_notifier_host_registered { get { return true; } }
  public int protocol_version { get { return 0; } }

  public string[] registered_status_notifier_items {
    owned get {
      return items.to_array ();
    }
  }

  public StatusNotifierWatcherImpl (Docky.TrayDockItem item) {
    dock_item = item;
    items = new Gee.ArrayList<string> ();
  }

  public void register_status_notifier_item (string service, BusName sender) throws Error {
    string full_service;
    if (service.has_prefix ("/")) {
      // Path-only registration — use sender bus name + path
      full_service = ((string) sender) + service;
    } else if (service.has_prefix (":")) {
      full_service = service;
    } else {
      full_service = service;
    }

    if (!items.contains (full_service)) {
      items.add (full_service);
      status_notifier_item_registered (full_service);
      dock_item.on_items_changed ();
      debug ("SNI registered: %s", full_service);
    }
  }

  public void register_status_notifier_host (string service) throws Error {
    status_notifier_host_registered ();
  }

  public void unregister_item (string service) {
    if (items.remove (service)) {
      status_notifier_item_unregistered (service);
      dock_item.on_items_changed ();
      debug ("SNI unregistered: %s", service);
    }
  }

  public bool has_item (string service) {
    return items.contains (service);
  }
}

namespace Docky {

  private struct TrayItemInfo {
    public string service;
    public string bus_name;
    public string object_path;
    public string title;
    public string icon_name;
    public string icon_theme_path;
    public string id;
  }

  public class TrayDockItem : DockletItem {
    private const string ICON_NAME = "system-tray";
    private const string ICON_RESOURCE = "resource://" + G_RESOURCE_PATH + "/icons/system-tray.svg";
    private const string ICON_PATH = ICON_NAME + ";;" + ICON_RESOURCE;

    private StatusNotifierWatcherImpl? watcher_impl = null;
    private FreedesktopDBus? dbus_proxy = null;
    private uint bus_owner_id = 0;
    private uint name_watch_id = 0;
    private Gee.ArrayList<TrayItemInfo?> tray_items;
    private Gtk.Window? popup_window = null;
    private Gtk.Box? items_box = null;
    private bool popup_visible = false;

    public TrayDockItem.with_dockitem_file (GLib.File file)
    {
      GLib.Object (Prefs : new DockItemPreferences.with_file (file));
    }

    construct
    {
      Icon = ICON_PATH;
      Text = _("System Tray");
      tray_items = new Gee.ArrayList<TrayItemInfo?> ();

      start_watcher.begin ();
    }

    ~TrayDockItem () {
      if (bus_owner_id > 0)
        Bus.unown_name (bus_owner_id);

      if (name_watch_id > 0)
        Bus.unwatch_name (name_watch_id);

      dbus_proxy = null;

      if (popup_window != null) {
        popup_window.destroy ();
        popup_window = null;
      }
    }

    private async void start_watcher () {
      try {
        dbus_proxy = yield Bus.get_proxy (BusType.SESSION,
          "org.freedesktop.DBus",
          "/org/freedesktop/DBus");
      } catch (Error e) {
        warning ("Failed to get D-Bus proxy: %s", e.message);
      }

      watcher_impl = new StatusNotifierWatcherImpl (this);

      bus_owner_id = Bus.own_name (BusType.SESSION,
        "org.kde.StatusNotifierWatcher",
        BusNameOwnerFlags.NONE,
        (conn) => {
          try {
            conn.register_object ("/StatusNotifierWatcher", watcher_impl);
            debug ("StatusNotifierWatcher registered on D-Bus");
            // Scan for existing SNI items after registration
            scan_existing_items.begin ();
          } catch (IOError e) {
            warning ("Failed to register watcher: %s", e.message);
          }
        },
        () => { debug ("Acquired org.kde.StatusNotifierWatcher"); },
        () => { warning ("Lost org.kde.StatusNotifierWatcher name"); }
      );

      // Watch for bus names disappearing to clean up stale items
      name_watch_id = Bus.watch_name (BusType.SESSION,
        "org.freedesktop.DBus",
        BusNameWatcherFlags.NONE,
        null,
        null
      );

      // Monitor NameOwnerChanged for cleanup
      try {
        var conn = yield Bus.get (BusType.SESSION);
        conn.signal_subscribe (
          "org.freedesktop.DBus",
          "org.freedesktop.DBus",
          "NameOwnerChanged",
          "/org/freedesktop/DBus",
          null,
          DBusSignalFlags.NONE,
          on_name_owner_changed
        );
      } catch (Error e) {
        warning ("Failed to subscribe to NameOwnerChanged: %s", e.message);
      }
    }

    private void on_name_owner_changed (DBusConnection conn, string? sender,
        string object_path, string interface_name, string signal_name,
        Variant parameters) {
      string name, old_owner, new_owner;
      parameters.get ("(sss)", out name, out old_owner, out new_owner);

      // If a name disappeared, remove its tray items
      if (new_owner == "" && old_owner != "" && watcher_impl != null) {
        // Check registered items for this bus name
        foreach (string item in watcher_impl.registered_status_notifier_items) {
          if (item.has_prefix (old_owner) || item == name) {
            watcher_impl.unregister_item (item);
          }
        }
      }
    }

    private async void scan_existing_items () {
      if (dbus_proxy == null)
        return;

      try {
        string[] names = dbus_proxy.list_names ();
        foreach (unowned string name in names) {
          if (name.has_prefix (":"))
            continue;

          // Try to check if this name implements StatusNotifierItem
          try {
            var proxy = yield Bus.get_proxy<StatusNotifierItemProxy> (BusType.SESSION,
              name, "/StatusNotifierItem",
              DBusProxyFlags.DO_NOT_AUTO_START | DBusProxyFlags.DO_NOT_CONNECT_SIGNALS);
            // If we got here, it has the interface — try to read id
            try {
              var id = proxy.id;
              if (id != null && id != "") {
                watcher_impl.register_status_notifier_item (name, new BusName (name));
              }
            } catch {}
          } catch {}
        }
      } catch (Error e) {
        warning ("Failed to scan existing items: %s", e.message);
      }

      yield refresh_items ();
    }

    public void on_items_changed () {
      refresh_items.begin ();
    }

    private async void refresh_items () {
      tray_items.clear ();

      if (watcher_impl == null) {
        update_badge ();
        return;
      }

      string[] items = watcher_impl.registered_status_notifier_items;

      foreach (unowned string service in items) {
        var info = yield fetch_item_info (service);
        if (info != null)
          tray_items.add (info);
      }

      update_badge ();
      reset_icon_buffer ();
      build_menu ();
    }

    private async TrayItemInfo? fetch_item_info (string service) {
      string bus_name;
      string object_path;

      // Service format can be ":1.23/org/path" or just "org.name"
      if ("/" in service) {
        var parts = service.split ("/", 2);
        bus_name = parts[0];
        object_path = "/" + parts[1];
      } else {
        bus_name = service;
        object_path = "/StatusNotifierItem";
      }

      try {
        var proxy = yield Bus.get_proxy<StatusNotifierItemProxy> (BusType.SESSION,
          bus_name, object_path);

        var info = TrayItemInfo ();
        info.service = service;
        info.bus_name = bus_name;
        info.object_path = object_path;

        try { info.title = proxy.title ?? ""; } catch { info.title = ""; }
        try { info.icon_name = proxy.icon_name ?? ""; } catch { info.icon_name = ""; }
        try { info.icon_theme_path = proxy.icon_theme_path ?? ""; } catch { info.icon_theme_path = ""; }
        try { info.id = proxy.id ?? ""; } catch { info.id = ""; }

        // Use id as fallback title
        if (info.title == "" && info.id != "")
          info.title = info.id;
        if (info.title == "")
          info.title = bus_name;

        return info;
      } catch (Error e) {
        warning ("Failed to query tray item %s: %s", service, e.message);
        return null;
      }
    }

    private void update_badge () {
      int count = tray_items.size;
      Count = (int64) count;
      CountVisible = count > 0;
    }

    private void build_menu () {
      // Menu content is built on-the-fly in populate_popup
    }

    private void style_popup (Gtk.Window win) {
      win.set_visual (win.get_screen ().get_rgba_visual ());
      win.app_paintable = true;

      var css = new Gtk.CssProvider ();
      try {
        css.load_from_data ("""
          .plank-popup {
            background-color: @theme_bg_color;
            border: 1px solid alpha(@theme_fg_color, 0.2);
            border-radius: 12px;
            padding: 4px;
          }
        """);
      } catch (Error e) {
        warning ("Failed to load popup CSS: %s", e.message);
      }
      win.get_style_context ().add_provider (css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
      win.get_style_context ().add_class ("plank-popup");

      win.draw.connect ((cr) => {
        var ctx = win.get_style_context ();
        var alloc = Gtk.Allocation ();
        win.get_allocation (out alloc);
        cr.save ();
        cr.set_source_rgba (0, 0, 0, 0);
        cr.set_operator (Cairo.Operator.SOURCE);
        cr.paint ();
        cr.restore ();
        ctx.render_background (cr, 0, 0, alloc.width, alloc.height);
        ctx.render_frame (cr, 0, 0, alloc.width, alloc.height);
        return false;
      });
    }

    private void ensure_popup () {
      if (popup_window != null) return;

      popup_window = new Gtk.Window (Gtk.WindowType.TOPLEVEL);
      popup_window.type_hint = Gdk.WindowTypeHint.POPUP_MENU;
      popup_window.decorated = false;
      popup_window.resizable = false;
      popup_window.skip_taskbar_hint = true;
      popup_window.skip_pager_hint = true;
      popup_window.set_keep_above (true);
      style_popup (popup_window);

      var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
      vbox.margin = 6;

      items_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
      items_box.set_size_request (220, -1);
      vbox.pack_start (items_box, false, false, 0);

      popup_window.add (vbox);

      popup_window.key_press_event.connect ((event) => {
        if (event.keyval == Gdk.Key.Escape) {
          hide_popup ();
          return true;
        }
        return false;
      });

      popup_window.focus_out_event.connect (() => {
        Timeout.add (150, () => {
          if (popup_window != null && !popup_window.has_toplevel_focus) {
            hide_popup ();
          }
          return false;
        });
        return false;
      });
    }

    private void populate_popup () {
      if (items_box == null) return;

      foreach (var child in items_box.get_children ())
        items_box.remove (child);

      if (tray_items.size == 0) {
        var label = new Gtk.Label (_("No tray items"));
        label.sensitive = false;
        label.margin = 6;
        label.show ();
        items_box.pack_start (label, false, false, 0);
        return;
      }

      foreach (var info in tray_items) {
        var row = create_tray_row (info);
        items_box.pack_start (row, false, false, 0);
      }

      items_box.show_all ();
    }

    private Gtk.Box create_tray_row (TrayItemInfo info) {
      int width, height;
      Gtk.icon_size_lookup (Gtk.IconSize.MENU, out width, out height);

      var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
      row.margin_start = 4;
      row.margin_end = 4;
      row.margin_top = 2;
      row.margin_bottom = 2;

      Gtk.Image image;
      if (info.icon_name != "") {
        Gdk.Pixbuf? pixbuf = null;
        // Try loading from app's custom icon theme path first
        if (info.icon_theme_path != "") {
          var icon_file = "%s/%s.png".printf (info.icon_theme_path, info.icon_name);
          try {
            pixbuf = new Gdk.Pixbuf.from_file_at_scale (icon_file, width, height, true);
          } catch {}
        }
        // Fallback to standard icon theme
        if (pixbuf == null)
          pixbuf = DrawingService.load_icon (info.icon_name, width, height);
        if (pixbuf != null)
          image = new Gtk.Image.from_pixbuf (pixbuf);
        else
          image = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.MENU);
      } else {
        image = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.MENU);
      }

      // Activate button (app name)
      var activate_btn = new Gtk.Button ();
      activate_btn.relief = Gtk.ReliefStyle.NONE;
      var btn_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
      btn_box.pack_start (image, false, false, 0);
      var label = new Gtk.Label (info.title);
      label.halign = Gtk.Align.START;
      label.ellipsize = Pango.EllipsizeMode.END;
      btn_box.pack_start (label, true, true, 0);
      activate_btn.add (btn_box);
      activate_btn.hexpand = true;

      var act_bus = info.bus_name;
      var act_path = info.object_path;
      activate_btn.clicked.connect (() => {
        activate_tray_item.begin (act_bus, act_path);
        hide_popup ();
      });

      // Kill button (window-close style)
      var kill_btn = new Gtk.Button.from_icon_name ("window-close-symbolic", Gtk.IconSize.MENU);
      kill_btn.relief = Gtk.ReliefStyle.NONE;
      kill_btn.tooltip_text = _("Kill Process");
      var kill_css = new Gtk.CssProvider ();
      try {
        kill_css.load_from_data ("""
          button.tray-close {
            min-width: 24px;
            min-height: 24px;
            padding: 0;
            border-radius: 12px;
          }
          button.tray-close:hover {
            background-color: #e74c3c;
            color: white;
          }
        """);
      } catch {}
      kill_btn.get_style_context ().add_provider (kill_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
      kill_btn.get_style_context ().add_class ("tray-close");
      var kill_bus = info.bus_name;
      kill_btn.clicked.connect (() => {
        kill_tray_item (kill_bus);
        hide_popup ();
      });

      row.pack_start (activate_btn, true, true, 0);
      row.pack_end (kill_btn, false, false, 0);

      return row;
    }

    private void kill_tray_item (string bus_name) {
      uint32 pid = get_pid_for_bus_name (bus_name);
      if (pid > 0) {
        try {
          // SIGTERM first, then SIGKILL after 1s if still alive
          Process.spawn_command_line_async (
            "/bin/sh -c 'kill %u 2>/dev/null; sleep 1; kill -0 %u 2>/dev/null && pkill -9 -P %u; kill -9 %u 2>/dev/null' ".printf (pid, pid, pid, pid));
        } catch (Error e) {
          warning ("Failed to kill PID %u: %s", pid, e.message);
        }
        Timeout.add (500, () => {
          refresh_items.begin ();
          return false;
        });
      }
    }

    private uint32 get_pid_for_bus_name (string bus_name) {
      if (dbus_proxy == null)
        return 0;

      try {
        return dbus_proxy.get_connection_unix_process_id (bus_name);
      } catch (Error e) {
        warning ("Failed to get PID for %s: %s", bus_name, e.message);
        return 0;
      }
    }

    private async void activate_tray_item (string bus_name, string object_path) {
      // Try SNI Activate first
      try {
        var proxy = yield Bus.get_proxy<StatusNotifierItemProxy> (BusType.SESSION,
          bus_name, object_path);
        proxy.activate (0, 0);
        return;
      } catch {}

      // Fallback: raise window by PID using xdg-activate or xdotool
      uint32 pid = get_pid_for_bus_name (bus_name);
      if (pid > 0) {
        // Use plank's WindowControl via Bamf matcher
        var matcher = Plank.Matcher.get_default ();
        foreach (var app in matcher.active_launchers ()) {
          if (app is Bamf.Application) {
            foreach (var child in app.get_children ()) {
              if (child is Bamf.Window) {
                var bw = (Bamf.Window) child;
                if (bw.get_pid () == (uint32) pid) {
                  Plank.WindowControl.focus_window (bw, Gtk.get_current_event_time ());
                  return;
                }
              }
            }
          }
        }
      }
    }

    public override bool toggle () {
      if (popup_visible) {
        hide_popup ();
      } else {
        refresh_items.begin ((obj, res) => {
          refresh_items.end (res);
          show_popup ();
        });
      }
      return true;
    }

    protected override AnimationType on_scrolled (Gdk.ScrollDirection direction,
                                                   Gdk.ModifierType mod, uint32 event_time) {
      return AnimationType.NONE;
    }

    protected override AnimationType on_clicked (PopupButton button,
                                                  Gdk.ModifierType mod, uint32 event_time) {
      if ((button & PopupButton.LEFT) != 0) {
        if (popup_visible) {
          hide_popup ();
        } else {
          refresh_items.begin ((obj, res) => {
            refresh_items.end (res);
            show_popup ();
          });
        }
        return AnimationType.NONE;
      }

      return AnimationType.NONE;
    }

    private void show_popup () {
      DockController? controller = get_dock ();
      if (controller == null) return;

      ensure_popup ();
      populate_popup ();

      popup_window.show_all ();

      Gtk.Requisition req;
      popup_window.get_preferred_size (null, out req);

      int win_x, win_y;
      controller.window.get_position (out win_x, out win_y);

      var icon_rect = controller.position_manager.get_hover_region_for_element (this);
      int icon_center_x = win_x + icon_rect.x + icon_rect.width / 2;
      int icon_center_y = win_y + icon_rect.y + icon_rect.height / 2;

      int x, y;

      switch (controller.position_manager.Position) {
      case Gtk.PositionType.BOTTOM:
        x = icon_center_x - req.width / 2;
        y = win_y + icon_rect.y - req.height;
        break;
      case Gtk.PositionType.TOP:
        x = icon_center_x - req.width / 2;
        y = win_y + icon_rect.y + icon_rect.height;
        break;
      case Gtk.PositionType.LEFT:
        x = win_x + icon_rect.x + icon_rect.width;
        y = icon_center_y - req.height / 2;
        break;
      case Gtk.PositionType.RIGHT:
        x = win_x - req.width;
        y = icon_center_y - req.height / 2;
        break;
      default:
        x = icon_center_x - req.width / 2;
        y = win_y - req.height;
        break;
      }

      popup_window.move (x, y);
      popup_window.present ();
      popup_visible = true;

      controller.window.update_hovered (0, 0);
      controller.renderer.animated_draw ();
    }

    private void hide_popup () {
      if (popup_window != null)
        popup_window.hide ();
      popup_visible = false;

      DockController? controller = get_dock ();
      if (controller == null) return;

      controller.renderer.animated_draw ();
      controller.hide_manager.update_hovered ();
      if (!controller.hide_manager.Hovered)
        controller.window.update_hovered (0, 0);
    }
  }
}
