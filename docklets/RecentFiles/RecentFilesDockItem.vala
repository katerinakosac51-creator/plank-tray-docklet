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

namespace Docky {
  public class RecentFilesDockItem : DockletItem {

    private RecentFilesPreferences prefs {
      get { return (RecentFilesPreferences) Prefs; }
    }

    private Gtk.RecentManager recent_manager;
    private Gtk.Menu? menu_widget = null;

    public RecentFilesDockItem.with_dockitem_file (GLib.File file)
    {
      GLib.Object (Prefs : new RecentFilesPreferences.with_file (file));
    }

    construct
    {
      Icon = RecentFilesDocklet.ICON;
      Text = _("Recent Files");

      recent_manager = Gtk.RecentManager.get_default ();
      recent_manager.changed.connect (on_recent_changed);

      prefs.notify["MaxItems"].connect (() => { rebuild (); });

      rebuild ();
    }

    ~RecentFilesDockItem () {
      recent_manager.changed.disconnect (on_recent_changed);

      if (menu_widget != null) {
        menu_widget.show.disconnect (on_menu_show);
        menu_widget.hide.disconnect (on_menu_hide);
        menu_widget = null;
      }
    }

    private void on_recent_changed () {
      rebuild ();
    }

    private void rebuild () {
      build_menu ();
      var items = recent_manager.get_items ();
      int count = int.min ((int) items.length (), prefs.MaxItems);
      Count = (int64) count;
      CountVisible = count > 0;
      Text = ngettext ("%d recent file", "%d recent files", count).printf (count);
    }

    private void build_menu () {
      DockController? controller = get_dock ();
      if (controller == null)
        return;

      if (menu_widget == null) {
        menu_widget = new Gtk.Menu ();
        menu_widget.reserve_toggle_size = false;
        menu_widget.show.connect (on_menu_show);
        menu_widget.hide.connect (on_menu_hide);
        menu_widget.attach_to_widget (controller.window, null);
      } else {
        foreach (var w in menu_widget.get_children ())
          menu_widget.remove (w);
      }

      var items = recent_manager.get_items ();

      // Sort by most recent first
      items.sort ((a, b) => {
        return (int) (b.get_modified () - a.get_modified ());
      });

      if (items.length () == 0) {
        var empty = new Gtk.MenuItem.with_label (_("No recent files"));
        empty.sensitive = false;
        empty.show ();
        menu_widget.append (empty);
        return;
      }

      int count = 0;
      foreach (unowned Gtk.RecentInfo info in items) {
        if (count >= prefs.MaxItems)
          break;

        if (!info.exists ())
          continue;

        var item = create_recent_menu_item (info);
        item.show ();
        menu_widget.append (item);
        count++;
      }

      // Separator + Clear Recent
      var sep = new Gtk.SeparatorMenuItem ();
      sep.show ();
      menu_widget.append (sep);

      var clear_item = new Gtk.MenuItem.with_label (_("Clear Recent Files"));
      clear_item.activate.connect (() => {
        try {
          recent_manager.purge_items ();
        } catch (Error e) {
          warning ("Failed to clear recent files: %s", e.message);
        }
      });
      clear_item.show ();
      menu_widget.append (clear_item);
    }

    private Gtk.MenuItem create_recent_menu_item (Gtk.RecentInfo info) {
      int width, height;
      Gtk.icon_size_lookup (Gtk.IconSize.MENU, out width, out height);

      var item = new Gtk.MenuItem ();
      var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

      // Icon
      Gtk.Image image;
      var gicon = info.get_gicon ();
      if (gicon != null) {
        var icon_name = DrawingService.get_icon_from_gicon (gicon) ?? "text-x-generic";
        var pixbuf = DrawingService.load_icon (icon_name, width, height);
        if (pixbuf != null) {
          image = new Gtk.Image.from_pixbuf (pixbuf);
        } else {
          image = new Gtk.Image.from_icon_name ("text-x-generic", Gtk.IconSize.MENU);
        }
      } else {
        image = new Gtk.Image.from_icon_name ("text-x-generic", Gtk.IconSize.MENU);
      }

      // Label: filename + parent dir hint
      var display = info.get_display_name () ?? "Unknown";
      var label = new Gtk.Label (display);
      label.halign = Gtk.Align.START;
      label.valign = Gtk.Align.CENTER;
      label.ellipsize = Pango.EllipsizeMode.MIDDLE;
      label.max_width_chars = 40;

      box.pack_start (image, false, false, 0);
      box.pack_start (label, true, true, 0);

      item.add (box);
      item.show_all ();

      // Submenu with actions
      var submenu = new Gtk.Menu ();
      submenu.reserve_toggle_size = false;

      var uri = info.get_uri ();

      // Open
      var open_item = new Gtk.MenuItem.with_label (_("Open"));
      var open_uri = uri;
      open_item.activate.connect (() => {
        try {
          AppInfo.launch_default_for_uri (open_uri, null);
        } catch (Error e) {
          warning ("Failed to open %s: %s", open_uri, e.message);
        }
      });
      open_item.show ();
      submenu.append (open_item);

      // Show in File Manager
      var show_item = new Gtk.MenuItem.with_label (_("Show in File Manager"));
      var show_uri = uri;
      show_item.activate.connect (() => {
        try {
          var parent = File.new_for_uri (show_uri).get_parent ();
          if (parent != null)
            AppInfo.launch_default_for_uri (parent.get_uri (), null);
        } catch (Error e) {
          warning ("Failed to show in file manager: %s", e.message);
        }
      });
      show_item.show ();
      submenu.append (show_item);

      var sep = new Gtk.SeparatorMenuItem ();
      sep.show ();
      submenu.append (sep);

      // Remove from Recent
      var remove_item = new Gtk.MenuItem.with_label (_("Remove from Recent"));
      var remove_uri = uri;
      remove_item.activate.connect (() => {
        try {
          recent_manager.remove_item (remove_uri);
        } catch (Error e) {
          warning ("Failed to remove recent item: %s", e.message);
        }
      });
      remove_item.show ();
      submenu.append (remove_item);

      item.submenu = submenu;

      return item;
    }

    private void on_menu_show () {
      DockController? controller = get_dock ();
      if (controller == null)
        return;

      controller.window.update_hovered (0, 0);
      controller.renderer.animated_draw ();
    }

    private void on_menu_hide () {
      DockController? controller = get_dock ();
      if (controller == null)
        return;

      controller.renderer.animated_draw ();
      controller.hide_manager.update_hovered ();
      if (!controller.hide_manager.Hovered)
        controller.window.update_hovered (0, 0);
    }

    protected override AnimationType on_scrolled (Gdk.ScrollDirection direction,
                                                   Gdk.ModifierType mod, uint32 event_time) {
      return AnimationType.NONE;
    }

    protected override AnimationType on_clicked (PopupButton button,
                                                  Gdk.ModifierType mod, uint32 event_time) {
      if ((button & PopupButton.LEFT) != 0) {
        rebuild ();
        show_recent_menu ();
        return AnimationType.NONE;
      }

      return AnimationType.NONE;
    }

    private void show_recent_menu () {
      DockController? controller = get_dock ();
      if (controller == null || menu_widget == null)
        return;

      Gtk.Requisition requisition;
      menu_widget.get_preferred_size (null, out requisition);

      int x, y;
      controller.position_manager.get_menu_position (this, requisition, out x, out y);

      Gdk.Gravity gravity;
      Gdk.Gravity flipped_gravity;

      switch (controller.position_manager.Position) {
      case Gtk.PositionType.BOTTOM:
        gravity = Gdk.Gravity.NORTH;
        flipped_gravity = Gdk.Gravity.SOUTH;
        break;
      case Gtk.PositionType.TOP:
        gravity = Gdk.Gravity.SOUTH;
        flipped_gravity = Gdk.Gravity.NORTH;
        break;
      case Gtk.PositionType.LEFT:
        gravity = Gdk.Gravity.EAST;
        flipped_gravity = Gdk.Gravity.WEST;
        break;
      case Gtk.PositionType.RIGHT:
        gravity = Gdk.Gravity.WEST;
        flipped_gravity = Gdk.Gravity.EAST;
        break;
      default:
        gravity = Gdk.Gravity.NORTH;
        flipped_gravity = Gdk.Gravity.SOUTH;
        break;
      }

      menu_widget.popup_at_rect (
        controller.window.get_screen ().get_root_window (),
        Gdk.Rectangle () {
          x = x,
          y = y,
          width = 1,
          height = 1,
        },
        gravity,
        flipped_gravity,
        null
      );
    }
  }
}
