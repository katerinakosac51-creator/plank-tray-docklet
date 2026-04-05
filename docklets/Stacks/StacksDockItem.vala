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

  private class StackFileInfo {
    public string name;
    public string display_name;
    public string icon_name;
    public string uri;
    public uint64 modified;
    public uint64 size;
    public FileType file_type;

    public StackFileInfo (string name, string display_name, string icon_name,
                          string uri, uint64 modified, uint64 size, FileType file_type) {
      this.name = name;
      this.display_name = display_name;
      this.icon_name = icon_name;
      this.uri = uri;
      this.modified = modified;
      this.size = size;
      this.file_type = file_type;
    }
  }

  public class StacksDockItem : DockletItem {
    private const string FILE_ATTRIBUTES =
      FileAttribute.STANDARD_NAME + ","
      + FileAttribute.STANDARD_DISPLAY_NAME + ","
      + FileAttribute.STANDARD_ICON + ","
      + FileAttribute.STANDARD_TYPE + ","
      + FileAttribute.STANDARD_IS_HIDDEN + ","
      + FileAttribute.TIME_MODIFIED + ","
      + FileAttribute.STANDARD_SIZE;

    private StacksPreferences prefs {
      get { return (StacksPreferences) Prefs; }
    }

    private FileMonitor? dir_monitor = null;
    private File? monitored_dir = null;
    private Gee.ArrayList<StackFileInfo> file_list;
    private Gtk.Menu? menu_widget = null;

    public StacksDockItem.with_dockitem_file (GLib.File file)
    {
      GLib.Object (Prefs : new StacksPreferences.with_file (file));
    }

    construct
    {
      file_list = new Gee.ArrayList<StackFileInfo> ();

      // Default to ~/Downloads if no path set
      if (prefs.FolderPath == "") {
        prefs.FolderPath = Path.build_filename (Environment.get_home_dir (), "Downloads");
      }

      prefs.notify["FolderPath"].connect (on_folder_changed);
      prefs.notify["SortBy"].connect (() => { refresh (); });
      prefs.notify["ShowHidden"].connect (() => { refresh (); });
      prefs.notify["MaxItems"].connect (() => { refresh (); });

      setup_monitor ();
      refresh ();
    }

    ~StacksDockItem () {
      cleanup_monitor ();

      prefs.notify["FolderPath"].disconnect (on_folder_changed);

      if (menu_widget != null) {
        menu_widget.show.disconnect (on_menu_show);
        menu_widget.hide.disconnect (on_menu_hide);
        menu_widget = null;
      }
    }

    private void on_folder_changed () {
      cleanup_monitor ();
      setup_monitor ();
      refresh ();
    }

    private void setup_monitor () {
      monitored_dir = File.new_for_path (prefs.FolderPath);

      if (!monitored_dir.query_exists ()) {
        warning ("Stacks folder does not exist: %s", prefs.FolderPath);
        return;
      }

      try {
        dir_monitor = monitored_dir.monitor_directory (0);
        dir_monitor.changed.connect (on_dir_changed);
      } catch (Error e) {
        warning ("Could not monitor directory %s: %s", prefs.FolderPath, e.message);
      }
    }

    private void cleanup_monitor () {
      if (dir_monitor != null) {
        dir_monitor.changed.disconnect (on_dir_changed);
        dir_monitor.cancel ();
        dir_monitor = null;
      }
    }

    private void on_dir_changed (File f, File? other, FileMonitorEvent event) {
      refresh ();
    }

    private void refresh () {
      enumerate_files ();
      update_display ();
      build_menu ();
    }

    private void enumerate_files () {
      file_list.clear ();

      if (monitored_dir == null || !monitored_dir.query_exists ())
        return;

      try {
        var enumerator = monitored_dir.enumerate_children (
          FILE_ATTRIBUTES,
          FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
          null
        );

        if (enumerator == null)
          return;

        FileInfo? info = null;
        while ((info = enumerator.next_file ()) != null) {
          // Skip hidden files unless preference is set
          if (!prefs.ShowHidden && info.get_is_hidden ())
            continue;

          var name = info.get_name ();
          var display_name = info.get_display_name () ?? name;
          var icon_name = DrawingService.get_icon_from_gicon (info.get_icon ()) ?? "text-x-generic";
          var uri = monitored_dir.get_child (name).get_uri ();
          var modified = info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
          var size = info.get_attribute_uint64 (FileAttribute.STANDARD_SIZE);
          var file_type = info.get_file_type ();

          file_list.add (new StackFileInfo (name, display_name, icon_name, uri, modified, size, file_type));
        }

        enumerator.close (null);
      } catch (Error e) {
        warning ("Could not enumerate directory %s: %s", prefs.FolderPath, e.message);
      }

      // Sort
      file_list.sort ((a, b) => {
        switch (prefs.SortBy) {
        case StacksSortBy.NAME:
          return a.display_name.collate (b.display_name);
        case StacksSortBy.SIZE:
          return (int) (b.size - a.size).clamp (-1, 1);
        case StacksSortBy.MODIFIED:
        default:
          if (b.modified > a.modified) return 1;
          if (b.modified < a.modified) return -1;
          return 0;
        }
      });

      // Limit
      if (file_list.size > prefs.MaxItems) {
        var trimmed = new Gee.ArrayList<StackFileInfo> ();
        for (int i = 0; i < prefs.MaxItems; i++)
          trimmed.add (file_list[i]);
        file_list = trimmed;
      }
    }

    private void update_display () {
      var folder_name = Path.get_basename (prefs.FolderPath);
      Icon = StacksDocklet.ICON;
      Text = "%s (%d)".printf (folder_name, file_list.size);
      Count = (int64) file_list.size;
      CountVisible = file_list.size > 0;
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

      if (file_list.size == 0) {
        var empty_item = new Gtk.MenuItem.with_label (_("Empty folder"));
        empty_item.sensitive = false;
        empty_item.show ();
        menu_widget.append (empty_item);
        return;
      }

      foreach (var finfo in file_list) {
        var item = create_file_menu_item (finfo);
        item.show ();
        menu_widget.append (item);
      }

      // Separator + Open Folder
      var sep = new Gtk.SeparatorMenuItem ();
      sep.show ();
      menu_widget.append (sep);

      var open_folder = create_icon_menu_item (_("Open Folder"), "folder-open");
      open_folder.activate.connect (() => {
        try {
          AppInfo.launch_default_for_uri (monitored_dir.get_uri (), null);
        } catch (Error e) {
          warning ("Failed to open folder: %s", e.message);
        }
      });
      open_folder.show ();
      menu_widget.append (open_folder);
    }

    private Gtk.MenuItem create_file_menu_item (StackFileInfo finfo) {
      int width, height;
      Gtk.icon_size_lookup (Gtk.IconSize.MENU, out width, out height);

      var item = new Gtk.MenuItem ();
      var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

      Gtk.Image image;
      var pixbuf = DrawingService.load_icon (finfo.icon_name, width, height);
      if (pixbuf != null) {
        image = new Gtk.Image.from_pixbuf (pixbuf);
      } else {
        image = new Gtk.Image.from_icon_name ("text-x-generic", Gtk.IconSize.MENU);
      }

      var label = new Gtk.Label (finfo.display_name);
      label.halign = Gtk.Align.START;
      label.valign = Gtk.Align.CENTER;
      label.ellipsize = Pango.EllipsizeMode.MIDDLE;
      label.max_width_chars = 40;

      box.pack_start (image, false, false, 0);
      box.pack_start (label, true, true, 0);

      item.add (box);
      item.show_all ();

      // Build submenu with actions
      var submenu = new Gtk.Menu ();
      submenu.reserve_toggle_size = false;

      // Open
      var open_item = new Gtk.MenuItem.with_label (_("Open"));
      var open_uri = finfo.uri;
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
      show_item.activate.connect (() => {
        try {
          AppInfo.launch_default_for_uri (monitored_dir.get_uri (), null);
        } catch (Error e) {
          warning ("Failed to open folder: %s", e.message);
        }
      });
      show_item.show ();
      submenu.append (show_item);

      var sep1 = new Gtk.SeparatorMenuItem ();
      sep1.show ();
      submenu.append (sep1);

      // Move to Trash
      var trash_item = new Gtk.MenuItem.with_label (_("Move to Trash"));
      var trash_uri = finfo.uri;
      trash_item.activate.connect (() => {
        try {
          File.new_for_uri (trash_uri).trash (null);
        } catch (Error e) {
          warning ("Failed to trash %s: %s", trash_uri, e.message);
        }
      });
      trash_item.show ();
      submenu.append (trash_item);

      // Delete
      var delete_item = new Gtk.MenuItem.with_label (_("Delete"));
      var delete_uri = finfo.uri;
      delete_item.activate.connect (() => {
        try {
          File.new_for_uri (delete_uri).@delete (null);
        } catch (Error e) {
          warning ("Failed to delete %s: %s", delete_uri, e.message);
        }
      });
      delete_item.show ();
      submenu.append (delete_item);

      item.submenu = submenu;

      return item;
    }

    private Gtk.MenuItem create_icon_menu_item (string title, string icon_name) {
      int width, height;
      Gtk.icon_size_lookup (Gtk.IconSize.MENU, out width, out height);

      var item = new Gtk.MenuItem ();
      var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

      var pixbuf = DrawingService.load_icon (icon_name, width, height);
      Gtk.Image image;
      if (pixbuf != null) {
        image = new Gtk.Image.from_pixbuf (pixbuf);
      } else {
        image = new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.MENU);
      }

      var label = new Gtk.Label (title);
      label.halign = Gtk.Align.START;

      box.pack_start (image, false, false, 0);
      box.pack_start (label, true, true, 0);

      item.add (box);
      item.show_all ();

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
        refresh ();
        show_stacks_menu ();
        return AnimationType.NONE;
      }

      return AnimationType.NONE;
    }

    public override Gee.ArrayList<Gtk.MenuItem> get_menu_items () {
      var items = new Gee.ArrayList<Gtk.MenuItem> ();

      // Change Folder
      var change_folder_item = create_menu_item (_("Change Folder..."), "folder", false);
      change_folder_item.activate.connect (() => {
        show_folder_picker ();
      });
      items.add (change_folder_item);

      var sep = new Gtk.SeparatorMenuItem ();
      items.add (sep);

      // Sort options
      var sort_modified = new Gtk.CheckMenuItem.with_mnemonic (_("Sort by _Date"));
      sort_modified.active = prefs.SortBy == StacksSortBy.MODIFIED;
      sort_modified.activate.connect (() => { prefs.SortBy = StacksSortBy.MODIFIED; });
      items.add (sort_modified);

      var sort_name = new Gtk.CheckMenuItem.with_mnemonic (_("Sort by _Name"));
      sort_name.active = prefs.SortBy == StacksSortBy.NAME;
      sort_name.activate.connect (() => { prefs.SortBy = StacksSortBy.NAME; });
      items.add (sort_name);

      var sort_size = new Gtk.CheckMenuItem.with_mnemonic (_("Sort by _Size"));
      sort_size.active = prefs.SortBy == StacksSortBy.SIZE;
      sort_size.activate.connect (() => { prefs.SortBy = StacksSortBy.SIZE; });
      items.add (sort_size);

      var sep2 = new Gtk.SeparatorMenuItem ();
      items.add (sep2);

      // Show hidden
      var hidden_item = new Gtk.CheckMenuItem.with_mnemonic (_("Show _Hidden Files"));
      hidden_item.active = prefs.ShowHidden;
      hidden_item.activate.connect (() => { prefs.ShowHidden = !prefs.ShowHidden; });
      items.add (hidden_item);

      return items;
    }

    private void show_folder_picker () {
      var chooser = new Gtk.FileChooserDialog (
        _("Choose Folder"),
        null,
        Gtk.FileChooserAction.SELECT_FOLDER,
        _("Cancel"), Gtk.ResponseType.CANCEL,
        _("Select"), Gtk.ResponseType.ACCEPT
      );

      chooser.set_current_folder (prefs.FolderPath);

      if (chooser.run () == Gtk.ResponseType.ACCEPT) {
        prefs.FolderPath = chooser.get_filename ();
      }

      chooser.destroy ();
    }

    private void show_stacks_menu () {
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
