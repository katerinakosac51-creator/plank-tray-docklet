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

using Plank;

namespace Docky {
  private class AppEntry {
    public string name;
    public string name_lower;
    public string icon;
    public string desktop_path;

    public AppEntry (string name, string icon, string desktop_path) {
      this.name = name;
      this.name_lower = name.down ();
      this.icon = icon;
      this.desktop_path = desktop_path;
    }
  }

  public class ApplicationsDockItem : DockletItem {
    private uint update_timer_id = 0;
    private GMenu.Tree menu_tree;
    private Gtk.Window? popup_window = null;
    private bool apps_loaded = false;
    private bool load_in_progress = false;
    private bool reload_requested = false;
    private Gtk.IconTheme icon_theme = Gtk.IconTheme.get_default();

    // Search state
    private Gee.ArrayList<AppEntry> all_apps;
    private Gtk.Entry? search_entry = null;
    private Gtk.Box? search_results_box = null;
    private Gtk.ScrolledWindow? search_scroll = null;
    private bool popup_visible = false;

    private const string APPLICATIONS_MENU = "applications.menu";
    private const string CINNAMON_APPLICATIONS_MENU = "cinnamon-applications.menu";
    private const string MATE_APPLICATIONS_MENU = "mate-applications.menu";

    private ApplicationsPreferences prefs {
      get { return (ApplicationsPreferences) Prefs; }
    }

    public ApplicationsDockItem.with_dockitem_file(GLib.File file)
    {
      GLib.Object(Prefs : new ApplicationsPreferences.with_file(file));
    }

    construct
    {
      all_apps = new Gee.ArrayList<AppEntry> ();
      update_icon();

      ((ApplicationsPreferences) Prefs).notify["CustomIcon"].connect(() => {
        update_icon();
      });

      Text = _("Applications");

      string menu_name = APPLICATIONS_MENU;

      switch (environment_session_desktop()) {
      case XdgSessionDesktop.CINNAMON :
        menu_name = CINNAMON_APPLICATIONS_MENU;
        break;
      case XdgSessionDesktop.MATE:
        menu_name = MATE_APPLICATIONS_MENU;
        break;
      }

      menu_tree = new GMenu.Tree(menu_name, GMenu.TreeFlags.SORT_DISPLAY_NAME);
      menu_tree.changed.connect(on_apps_menu_changed);

      icon_theme.changed.connect(on_apps_menu_changed);
      schedule_menu_update();
    }

    private void update_icon() {
      string custom_icon = prefs.CustomIcon;
      if (custom_icon != null && custom_icon != "") {
        Icon = custom_icon;
      } else {
        Icon = ApplicationsDocklet.ICON;
      }
    }

    ~ApplicationsDockItem() {
      if (update_timer_id > 0) {
        Source.remove(update_timer_id);
        update_timer_id = 0;
      }

      if (menu_tree != null) {
        menu_tree.changed.disconnect(on_apps_menu_changed);
        menu_tree = null;
      }

      if (popup_window != null) {
        popup_window.destroy ();
        popup_window = null;
      }

      icon_theme.changed.disconnect(on_apps_menu_changed);
    }

    private void on_apps_menu_changed() {
      schedule_menu_update();
    }

    private void schedule_menu_update() {
      if (update_timer_id > 0) {
        Source.remove(update_timer_id);
        update_timer_id = 0;
      }

      update_timer_id = Timeout.add(2000, () => {
        update_timer_id = 0;
        do_menu_update.begin();
        return false;
      });
    }

    private async void do_menu_update() {
      if (load_in_progress) {
        reload_requested = true;
        return;
      }

      if (menu_tree == null) {
        return;
      }

      load_in_progress = true;
      reload_requested = false;

      try {
        yield Worker.get_default().add_task_with_result<void*>(() => {
          try {
            menu_tree.load_sync();
            apps_loaded = true;
          } catch (Error e) {
            warning("Failed to load applications (%s)", e.message);
            apps_loaded = false;
          }
          return null;
        }, TaskPriority.HIGH);
      } catch (Error e) {
        warning("Error scheduling menu load: %s", e.message);
        apps_loaded = false;
      }

      load_in_progress = false;

      if (apps_loaded) {
        collect_all_apps ();
      }

      if (reload_requested) {
        reload_requested = false;
        schedule_menu_update();
      }
    }

    protected override AnimationType on_scrolled(Gdk.ScrollDirection direction,
                                                 Gdk.ModifierType mod, uint32 event_time) {
      return AnimationType.NONE;
    }

    protected override AnimationType on_clicked(PopupButton button,
                                                Gdk.ModifierType mod, uint32 event_time) {
      if ((button & PopupButton.LEFT) != 0) {
        toggle_popup ();
        return AnimationType.NONE;
      }

      return AnimationType.NONE;
    }

    private void collect_all_apps () {
      all_apps.clear ();
      if (menu_tree == null) return;
      var root = menu_tree.get_root_directory ();
      if (root != null) collect_apps_recursive (root);
    }

    private void collect_apps_recursive (GMenu.TreeDirectory dir) {
      var iter = dir.iter ();
      GMenu.TreeItemType type;
      while ((type = iter.next ()) != GMenu.TreeItemType.INVALID) {
        if (type == GMenu.TreeItemType.DIRECTORY) {
          var subdir = iter.get_directory ();
          if (subdir != null) collect_apps_recursive (subdir);
        } else if (type == GMenu.TreeItemType.ENTRY) {
          var entry = iter.get_entry ();
          if (entry == null) continue;
          var info = entry.get_app_info ();
          if (info == null) continue;
          var path = entry.get_desktop_file_path ();
          if (path == null) continue;
          var icon = DrawingService.get_icon_from_gicon (info.get_icon ()) ?? "";
          var name = info.get_display_name () ?? _("Unknown");
          all_apps.add (new AppEntry (name, icon, path));
        }
      }
    }

    private void on_search_changed () {
      if (search_entry == null || search_results_box == null)
        return;

      var query = search_entry.text.down ().strip ();

      // Remove old search results
      foreach (var child in search_results_box.get_children ())
        search_results_box.remove (child);

      // Show matching apps (all when query is empty)
      int count = 0;
      foreach (var app in all_apps) {
        if (count >= 50) break;
        if (query == "" || app.name_lower.contains (query)) {
          var item = create_search_result_item (app);
          search_results_box.pack_start (item, false, false, 0);
          count++;
        }
      }

      if (count == 0) {
        var label = new Gtk.Label (_("No results"));
        label.sensitive = false;
        label.margin = 6;
        label.show ();
        search_results_box.pack_start (label, false, false, 0);
      }

      search_results_box.show_all ();
    }

    private void on_search_activate () {
      if (search_results_box == null) return;
      var children = search_results_box.get_children ();
      if (children.length () > 0) {
        var first = children.first ().data as Gtk.Button;
        if (first != null)
          first.clicked ();
      }
    }

    private Gtk.Button create_search_result_item (AppEntry app) {
      int width, height;
      Gtk.icon_size_lookup (Gtk.IconSize.MENU, out width, out height);

      var btn = new Gtk.Button ();
      btn.relief = Gtk.ReliefStyle.NONE;
      var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

      var pixbuf = DrawingService.load_icon (app.icon, width, height);
      Gtk.Image image;
      if (pixbuf != null)
        image = new Gtk.Image.from_pixbuf (pixbuf);
      else
        image = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.MENU);

      var label = new Gtk.Label (app.name);
      label.halign = Gtk.Align.START;
      label.ellipsize = Pango.EllipsizeMode.END;

      box.pack_start (image, false, false, 0);
      box.pack_start (label, true, true, 0);
      btn.add (box);

      var path = app.desktop_path;
      btn.clicked.connect (() => {
        System.get_default ().launch (File.new_for_path (path));
        hide_popup ();
      });

      btn.show_all ();
      return btn;
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

      // Rounded corners via CSS
      var css_provider = new Gtk.CssProvider ();
      try {
        css_provider.load_from_data ("window { border-radius: 12px; }");
      } catch (Error e) {
        warning ("Failed to load CSS: %s", e.message);
      }
      popup_window.get_style_context ().add_provider (css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
      popup_window.app_paintable = true;
      popup_window.set_visual (popup_window.get_screen ().get_rgba_visual ());

      var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
      vbox.margin = 6;

      // Search entry
      search_entry = new Gtk.Entry ();
      search_entry.placeholder_text = _("Search applications...");
      search_entry.secondary_icon_name = "edit-find-symbolic";
      search_entry.changed.connect (on_search_changed);
      search_entry.activate.connect (on_search_activate);
      vbox.pack_start (search_entry, false, false, 0);

      // Results
      search_results_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
      search_scroll = new Gtk.ScrolledWindow (null, null);
      search_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
      search_scroll.set_size_request (280, 400);
      search_scroll.add (search_results_box);
      vbox.pack_start (search_scroll, true, true, 0);

      popup_window.add (vbox);

      // Escape to close
      popup_window.key_press_event.connect ((event) => {
        if (event.keyval == Gdk.Key.Escape) {
          hide_popup ();
          return true;
        }
        return false;
      });

      // Close on focus loss
      popup_window.focus_out_event.connect (() => {
        // Delay slightly to allow clicks on the dock icon to toggle
        Timeout.add (150, () => {
          if (popup_window != null && !popup_window.has_toplevel_focus) {
            hide_popup ();
          }
          return false;
        });
        return false;
      });
    }

    private void toggle_popup () {
      if (popup_visible) {
        hide_popup ();
      } else {
        show_popup ();
      }
    }

    private void show_popup () {
      if (!apps_loaded || all_apps.size == 0) return;

      DockController? controller = get_dock();
      if (controller == null) return;

      ensure_popup ();

      // Clear and populate
      search_entry.text = "";
      on_search_changed ();

      // Show to get requisition
      popup_window.show_all ();

      Gtk.Requisition req;
      popup_window.get_preferred_size (null, out req);

      // Get dock window position and icon center
      int win_x, win_y;
      controller.window.get_position (out win_x, out win_y);

      var icon_rect = controller.position_manager.get_hover_region_for_element (this);
      int icon_center_x = win_x + icon_rect.x + icon_rect.width / 2;
      int icon_center_y = win_y + icon_rect.y + icon_rect.height / 2;

      int x, y;

      switch (controller.position_manager.Position) {
      case Gtk.PositionType.BOTTOM:
        x = icon_center_x;
        y = win_y + icon_rect.y - req.height;
        break;
      case Gtk.PositionType.TOP:
        x = icon_center_x;
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
        x = icon_center_x;
        y = win_y - req.height;
        break;
      }

      popup_window.move (x, y);
      popup_window.present ();
      popup_visible = true;

      // Ensure focus even when activated via global keybinding
      popup_window.present_with_time (Gdk.CURRENT_TIME);
      Idle.add (() => {
        if (search_entry != null) {
          search_entry.grab_focus ();
        }
        return false;
      });

      controller.window.update_hovered(0, 0);
      controller.renderer.animated_draw();
    }

    private void hide_popup () {
      if (popup_window != null) {
        popup_window.hide ();
      }
      popup_visible = false;

      DockController? controller = get_dock();
      if (controller == null) return;

      controller.renderer.animated_draw();
      controller.hide_manager.update_hovered();
      if (!controller.hide_manager.Hovered) {
        controller.window.update_hovered(0, 0);
      }
    }

    public override Gee.ArrayList<Gtk.MenuItem> get_menu_items() {
      var items = new Gee.ArrayList<Gtk.MenuItem> ();

      var desktop = environment_session_desktop();

      string? editor_desktop_file = null;
      string? editor_command = null;

      switch (desktop) {
      case XdgSessionDesktop.CINNAMON:
        editor_desktop_file = "cinnamon-menu-editor.desktop";
        editor_command = "cinnamon-menu-editor";
        break;

      case XdgSessionDesktop.MATE:
        editor_desktop_file = "mozo.desktop";
        editor_command = "mozo";
        break;

      case XdgSessionDesktop.XFCE:
        editor_desktop_file = "menulibre.desktop";
        editor_command = "menulibre";
        break;

      case XdgSessionDesktop.GNOME:
        editor_desktop_file = "alacarte.desktop";
        editor_command = "alacarte";
        break;

      case XdgSessionDesktop.KDE:
        editor_desktop_file = "kmenuedit.desktop";
        editor_command = "kmenuedit";
        break;

      default:
        break;
      }

      if (editor_desktop_file != null && editor_command != null) {
        var menu_editor_item = create_menu_item(_("Edit Menu"), "document-edit", false);
        menu_editor_item.activate.connect(() => {
          try {
            var app_info = new DesktopAppInfo(editor_desktop_file);
            if (app_info != null) {
              app_info.launch(null, null);
            } else {
              Process.spawn_command_line_async(editor_command);
            }
          } catch (Error e) {
            warning("Failed to launch menu editor (%s): %s", editor_command, e.message);
          }
        });
        items.add(menu_editor_item);

        var separator_item = new Gtk.SeparatorMenuItem();
        items.add(separator_item);
      }

      var custom_icon_item = create_menu_item(_("Choose Custom Icon"), "document-properties", false);
      custom_icon_item.activate.connect(() => {
        show_icon_picker();
      });
      items.add(custom_icon_item);

      if (prefs.CustomIcon != "") {
        var reset_icon_item = create_menu_item(_("Reset to Default Icon"), "edit-clear", false);
        reset_icon_item.activate.connect(() => {
          prefs.CustomIcon = "";
        });
        items.add(reset_icon_item);
      }

      var separator_item = new Gtk.SeparatorMenuItem();
      items.add(separator_item);

      var large_icons_item = new Gtk.CheckMenuItem.with_mnemonic(_("Large Icons"));
      large_icons_item.active = prefs.LargeIcons;
      large_icons_item.activate.connect(() => {
        prefs.LargeIcons = !prefs.LargeIcons;
      });
      items.add(large_icons_item);

      return items;
    }

    private void show_icon_picker() {
      var file_chooser = new Gtk.FileChooserDialog(
                                                   _("Select Custom Icon"),
                                                   null,
                                                   Gtk.FileChooserAction.OPEN,
                                                   _("Cancel"), Gtk.ResponseType.CANCEL,
                                                   _("Select"), Gtk.ResponseType.ACCEPT
      );

      string[] icon_paths = {
        "/usr/share/icons",
        "/usr/share/pixmaps",
        GLib.Environment.get_home_dir() + "/.local/share/icons"
      };

      foreach (var path in icon_paths) {
        var dir = File.new_for_path(path);
        if (dir.query_exists()) {
          file_chooser.set_current_folder(path);
          break;
        }
      }

      var filter = new Gtk.FileFilter();
      filter.set_name(_("Image Files"));
      filter.add_mime_type("image/png");
      filter.add_mime_type("image/jpeg");
      filter.add_mime_type("image/svg+xml");
      filter.add_mime_type("image/webp");
      filter.add_pattern("*.png");
      filter.add_pattern("*.jpg");
      filter.add_pattern("*.jpeg");
      filter.add_pattern("*.svg");
      filter.add_pattern("*.xpm");
      filter.add_pattern("*.webp");
      file_chooser.add_filter(filter);

      var preview = new Gtk.Image();
      preview.set_size_request(128, 128);
      file_chooser.set_preview_widget(preview);
      file_chooser.set_use_preview_label(false);

      file_chooser.update_preview.connect(() => {
        string? filename = file_chooser.get_preview_filename();
        if (filename == null) {
          file_chooser.set_preview_widget_active(false);
          return;
        }

        try {
          var pixbuf = new Gdk.Pixbuf.from_file_at_scale(filename, 128, 128, true);
          preview.set_from_pixbuf(pixbuf);
          file_chooser.set_preview_widget_active(true);
        } catch (Error e) {
          file_chooser.set_preview_widget_active(false);
        }
      });

      if (file_chooser.run() == Gtk.ResponseType.ACCEPT) {
        string uri = file_chooser.get_uri();
        prefs.CustomIcon = uri;
      }

      file_chooser.destroy();
    }
  }
}
