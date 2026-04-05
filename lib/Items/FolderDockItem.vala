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

namespace Plank {
  public class FolderDockItem : DockItem {
    public const string URI_PREFIX = "folder://";
    public const string DRAG_URI_PREFIX = "folder-member://";
    public const string DEFAULT_ICON = "folder;;folder-documents;;inode-directory";

    private Gtk.Window? popup_window = null;
    private Gtk.FlowBox? popup_flow = null;
    private bool popup_visible = false;
    private bool popup_launching = false;
    private uint indicator_timer_id = 0;
    private uint popup_focus_watch_id = 0;
    private string popup_current_folder_uri = "";
    private Gee.ArrayList<string> popup_navigation_stack = new Gee.ArrayList<string> ();

    public FolderDockItem.with_dockitem_file (GLib.File file) {
      GLib.Object (Prefs : new DockItemPreferences.with_file (file));
    }

    construct {
      Icon = DEFAULT_ICON;
      Prefs.notify["FolderMembers"].connect (on_folder_data_changed);
      Prefs.notify["FolderTitle"].connect (on_folder_data_changed);
      on_folder_data_changed ();

      indicator_timer_id = Timeout.add_seconds (1, () => {
        update_running_indicator ();
        return true;
      });
      update_running_indicator ();
    }

    ~FolderDockItem () {
      Prefs.notify["FolderMembers"].disconnect (on_folder_data_changed);
      Prefs.notify["FolderTitle"].disconnect (on_folder_data_changed);

      if (indicator_timer_id > 0) {
        Source.remove (indicator_timer_id);
        indicator_timer_id = 0;
      }

      if (popup_focus_watch_id > 0) {
        Source.remove (popup_focus_watch_id);
        popup_focus_watch_id = 0;
      }

      if (popup_window != null) {
        popup_window.destroy ();
        popup_window = null;
      }
    }

    public static bool is_folder_uri (string? uri) {
      return uri != null && uri.has_prefix (URI_PREFIX);
    }

    public static string make_folder_uri () {
      return URI_PREFIX + Uuid.string_random ();
    }

    public static string serialize_members (Gee.List<string> members) {
      return string.joinv (";;", (string[]) members.to_array ());
    }

    public static Gee.ArrayList<string> parse_members (string serialized) {
      var result = new Gee.ArrayList<string> ();
      if (serialized == null || serialized == "")
        return result;

      foreach (unowned string part in serialized.split (";;")) {
        var trimmed = part.strip ();
        if (trimmed != "")
          result.add (trimmed);
      }
      return result;
    }

    public static string encode_member_drag_uri (string folder_uri, string member_uri) {
      var uuid = folder_uri.substring (URI_PREFIX.length);
      return "%s%s/%s".printf (DRAG_URI_PREFIX, uuid, Uri.escape_string (member_uri, null, true));
    }

    public static bool decode_member_drag_uri (string uri, out string folder_uri, out string member_uri) {
      folder_uri = "";
      member_uri = "";

      if (!uri.has_prefix (DRAG_URI_PREFIX))
        return false;

      var payload = uri.substring (DRAG_URI_PREFIX.length);
      var slash = payload.index_of ("/");
      string uuid = "";
      string escaped_member = "";

      if (slash > 0 && slash < payload.length - 1) {
        uuid = payload.slice (0, slash);
        escaped_member = payload.substring (slash + 1);
      } else {
        // Backward compatibility for earlier payload format.
        var qpos = payload.index_of ("?");
        if (qpos <= 0 || qpos >= payload.length - 1)
          return false;
        uuid = payload.slice (0, qpos);
        var query = payload.substring (qpos + 1);
        if (!query.has_prefix ("member="))
          return false;
        escaped_member = query.substring (7);
      }

      var unescaped = Uri.unescape_string (escaped_member, null);
      if (unescaped == null || unescaped == "")
        return false;

      folder_uri = URI_PREFIX + uuid;
      member_uri = unescaped;
      return true;
    }

    public Gee.ArrayList<string> get_members () {
      return parse_members (Prefs.FolderMembers);
    }

    public int get_member_count () {
      return get_members ().size;
    }

    public string? get_single_remaining_member () {
      var members = get_members ();
      if (members.size != 1)
        return null;
      return members[0];
    }

    public void set_members (Gee.List<string> members) {
      Prefs.FolderMembers = serialize_members (members);
    }

    public bool add_member (string launcher_uri) {
      var members = get_members ();
      foreach (var member in members)
        if (member == launcher_uri)
          return false;

      members.add (launcher_uri);
      set_members (members);
      return true;
    }

    public bool remove_member (string launcher_uri) {
      var members = get_members ();
      if (!members.remove (launcher_uri))
        return false;

      set_members (members);
      return true;
    }

    public bool has_member (string launcher_uri) {
      var members = get_members ();
      foreach (var member in members)
        if (member == launcher_uri)
          return true;
      return false;
    }

    public override string get_drop_text () {
      return _("Drop to add to folder");
    }

    public override bool can_accept_drop (Gee.ArrayList<string> uris) {
      foreach (var uri in uris) {
        if (uri.has_prefix (DRAG_URI_PREFIX))
          return true;
        if (uri.has_suffix (".desktop"))
          return true;
        if (!uri.has_prefix (DOCKLET_URI_PREFIX))
          return true;
      }
      return false;
    }

    protected override void draw_icon (Surface surface) {
      var members = get_members ();
      if (members.size == 0) {
        base.draw_icon (surface);
        return;
      }

      var mini_icons = new Gee.ArrayList<Gdk.Pixbuf> ();
      int icon_count = int.min (4, members.size);
      int mini_size = int.max (16, surface.Width / 2 - 6);

      for (int i = 0; i < icon_count; i++) {
        var icon_name = member_icon_name (members[i]);
        var pbuf = DrawingService.load_icon (icon_name, mini_size, mini_size);
        if (pbuf != null)
          mini_icons.add (pbuf);
      }

      if (mini_icons.size == 0) {
        base.draw_icon (surface);
        return;
      }

      unowned Cairo.Context cr = surface.Context;
      cr.save ();

      // Folder plate background
      cr.set_source_rgba (0.18, 0.18, 0.2, 0.75);
      rounded_rectangle (cr, 1, 1, surface.Width - 2, surface.Height - 2, 10);
      cr.fill ();

      int cell_w = surface.Width / 2;
      int cell_h = surface.Height / 2;
      for (int i = 0; i < mini_icons.size; i++) {
        int col = i % 2;
        int row = i / 2;
        int x = col * cell_w + (cell_w - mini_icons[i].width) / 2;
        int y = row * cell_h + (cell_h - mini_icons[i].height) / 2;
        Gdk.cairo_set_source_pixbuf (cr, mini_icons[i], x, y);
        cr.paint ();
      }

      cr.restore ();
    }

    protected override AnimationType on_clicked (PopupButton button, Gdk.ModifierType mod, uint32 event_time) {
      if ((button & PopupButton.LEFT) != 0) {
        toggle_popup ();
        return AnimationType.NONE;
      }
      return AnimationType.NONE;
    }

    private static void rounded_rectangle (Cairo.Context cr, double x, double y, double w, double h, double r) {
      cr.new_sub_path ();
      cr.arc (x + w - r, y + r, r, -Math.PI / 2, 0);
      cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
      cr.arc (x + r, y + h - r, r, Math.PI / 2, Math.PI);
      cr.arc (x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
      cr.close_path ();
    }

    private void on_folder_data_changed () {
      var members = get_members ();
      var title = Prefs.FolderTitle.strip ();
      if (title != "")
        Text = title;
      else
        Text = build_auto_title (members);

      Count = 0;
      CountVisible = false;
      reset_icon_buffer ();
      if (popup_visible) {
        if (members.size <= 1)
          hide_popup ();
        else
          rebuild_popup ();
      }
    }

    private void update_running_indicator () {
      var members = get_members ();
      if (members.size == 0) {
        Indicator = IndicatorState.NONE;
        return;
      }

      var running = new Gee.HashSet<string> ();
      foreach (var app in Matcher.get_default ().active_launchers ()) {
        var desktop = app.get_desktop_file ();
        if (desktop == null || desktop == "")
          continue;
        try {
          running.add (Filename.to_uri (desktop));
        } catch (ConvertError e) {
          warning (e.message);
        }
      }

      bool has_running = false;
      foreach (var member in members) {
        if (!member.has_suffix (".desktop"))
          continue;
        if (running.contains (member)) {
          has_running = true;
          break;
        }
      }

      Indicator = has_running ? IndicatorState.SINGLE : IndicatorState.NONE;
    }

    private string member_icon_name (string launcher_uri) {
      if (launcher_uri.has_prefix (URI_PREFIX))
        return "folder";

      if (launcher_uri.has_prefix (DOCKLET_URI_PREFIX)) {
        var docklet = DockletManager.get_default ().get_docklet_by_uri (launcher_uri);
        if (docklet != null)
          return docklet.get_icon ();
      }

      if (launcher_uri.has_suffix (".desktop")) {
        string icon = "";
        string text = "";
        bool accepts_files = false;
        ApplicationDockItem.parse_launcher (launcher_uri, out icon, out text, null, null, null, out accepts_files);
        if (icon != "")
          return icon;
      } else {
        try {
          var info = File.new_for_uri (launcher_uri).query_info (FileAttribute.STANDARD_ICON, FileQueryInfoFlags.NONE);
          var icon = DrawingService.get_icon_from_gicon (info.get_icon ());
          if (icon != null && icon != "")
            return icon;
        } catch {}
      }
      return "application-x-executable";
    }

    private string member_display_name (string launcher_uri) {
      if (launcher_uri.has_prefix (URI_PREFIX))
        return folder_title_for_uri (launcher_uri);

      if (launcher_uri.has_prefix (DOCKLET_URI_PREFIX)) {
        var docklet = DockletManager.get_default ().get_docklet_by_uri (launcher_uri);
        if (docklet != null)
          return docklet.get_name ();
      }

      if (launcher_uri.has_suffix (".desktop")) {
        string icon = "";
        string text = "";
        bool accepts_files = false;
        ApplicationDockItem.parse_launcher (launcher_uri, out icon, out text, null, null, null, out accepts_files);
        if (text != "")
          return text;
      } else {
        try {
          var info = File.new_for_uri (launcher_uri).query_info (FileAttribute.STANDARD_DISPLAY_NAME, FileQueryInfoFlags.NONE);
          var name = info.get_display_name ();
          if (name != null && name != "")
            return name;
        } catch {}
      }
      return launcher_uri;
    }

    private void launch_member (string launcher_uri) {
      if (launcher_uri.has_prefix (URI_PREFIX))
        open_nested_folder (launcher_uri);
      else if (launcher_uri.has_prefix (DOCKLET_URI_PREFIX)) {
        // Find a live docklet item on the dock and trigger its click
        DockController? dock = get_dock ();
        if (dock != null) {
          foreach (unowned DockItem item in dock.Items) {
            if (item.Launcher == launcher_uri) {
              item.clicked (PopupButton.LEFT, 0, Gdk.CURRENT_TIME);
              return;
            }
          }
        }
        // No live item found — instantiate a temporary one and invoke it
        var docklet = DockletManager.get_default ().get_docklet_by_uri (launcher_uri);
        if (docklet != null) {
          var tmp_file = File.new_for_path (
            Path.build_filename (Environment.get_tmp_dir (), "plank-docklet-%s.dockitem".printf (launcher_uri.substring (DOCKLET_URI_PREFIX.length)))
          );
          var dockitem_file = Factory.item_factory.make_dock_item (launcher_uri, tmp_file.get_parent ());
          if (dockitem_file != null) {
            var element = docklet.make_element (launcher_uri, dockitem_file);
            unowned DockItem? tmp_item = (element as DockItem);
            if (tmp_item != null)
              tmp_item.clicked (PopupButton.LEFT, 0, Gdk.CURRENT_TIME);
            dockitem_file.delete_async.begin (GLib.Priority.DEFAULT, null, (obj, res) => {
              try { dockitem_file.delete_async.end (res); } catch {}
            });
          }
        }
      }
      else if (launcher_uri.has_suffix (".desktop"))
        System.get_default ().launch (File.new_for_uri (launcher_uri));
      else
        System.get_default ().open_uri (launcher_uri);
    }

    private void ensure_popup () {
      if (popup_window != null)
        return;

      popup_window = new Gtk.Window (Gtk.WindowType.TOPLEVEL);
      popup_window.type_hint = Gdk.WindowTypeHint.POPUP_MENU;
      popup_window.decorated = false;
      popup_window.resizable = false;
      popup_window.skip_taskbar_hint = true;
      popup_window.skip_pager_hint = true;
      popup_window.set_keep_above (true);
      popup_window.key_press_event.connect ((event) => {
        if (event.keyval == Gdk.Key.Escape) {
          hide_popup ();
          return true;
        }
        return false;
      });

      var frame = new Gtk.Frame (null);
      frame.shadow_type = Gtk.ShadowType.OUT;
      popup_window.add (frame);

      popup_flow = new Gtk.FlowBox ();
      popup_flow.max_children_per_line = 4;
      popup_flow.selection_mode = Gtk.SelectionMode.NONE;
      popup_flow.row_spacing = 6;
      popup_flow.column_spacing = 6;
      popup_flow.margin = 8;

      frame.add (popup_flow);

      popup_window.focus_out_event.connect (() => {
        Timeout.add (150, () => {
          if (popup_window != null && !popup_window.has_toplevel_focus && !popup_launching)
            hide_popup ();
          return false;
        });
        return false;
      });
    }

    private void rebuild_popup () {
      ensure_popup ();
      if (popup_flow == null)
        return;

      foreach (var child in popup_flow.get_children ())
        child.destroy ();

      if (popup_current_folder_uri == "")
        popup_current_folder_uri = Launcher;

      // Add folder title at the top
      var title_label = new Gtk.Label (Text);
      title_label.get_style_context ().add_class ("title");
      title_label.margin_bottom = 4;
      title_label.xalign = 0.5f;
      var attr_list = new Pango.AttrList ();
      attr_list.insert (Pango.attr_weight_new (Pango.Weight.BOLD));
      attr_list.insert (Pango.attr_scale_new (1.2));
      title_label.attributes = attr_list;
      popup_flow.add (title_label);

      if (popup_current_folder_uri != Launcher)
        popup_flow.add (create_back_widget ());

      var members = members_for_folder_uri (popup_current_folder_uri);
      foreach (var member in members)
        popup_flow.add (create_member_widget (member, popup_current_folder_uri));

      popup_flow.show_all ();
    }

    private Gtk.Widget create_back_widget () {
      var button = new Gtk.Button ();
      button.relief = Gtk.ReliefStyle.NONE;
      button.set_size_request (96, 96);

      var alignment = new Gtk.Alignment (0.5f, 0.5f, 0.0f, 0.0f);
      var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
      box.halign = Gtk.Align.CENTER;
      box.valign = Gtk.Align.CENTER;
      var image = new Gtk.Image.from_icon_name ("go-previous", Gtk.IconSize.DIALOG);
      var label = new Gtk.Label (_("Back"));
      label.justify = Gtk.Justification.CENTER;
      label.xalign = 0.5f;
      box.pack_start (image, false, false, 0);
      box.pack_start (label, false, false, 0);
      alignment.add (box);
      button.add (alignment);

      button.clicked.connect (() => {
        if (popup_navigation_stack.size > 0) {
          popup_current_folder_uri = popup_navigation_stack.remove_at (popup_navigation_stack.size - 1);
        } else {
          popup_current_folder_uri = Launcher;
        }
        rebuild_popup ();
      });

      return button;
    }

    private Gtk.Widget create_member_widget (string member_uri, string owner_folder_uri) {
      int width, height;
      Gtk.icon_size_lookup (Gtk.IconSize.DIALOG, out width, out height);
      var icon_name = member_icon_name (member_uri);
      var display = member_display_name (member_uri);

      var button = new Gtk.Button ();
      button.relief = Gtk.ReliefStyle.NONE;
      button.set_size_request (96, 96);
      var alignment = new Gtk.Alignment (0.5f, 0.5f, 0.0f, 0.0f);
      var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
      box.halign = Gtk.Align.CENTER;
      box.valign = Gtk.Align.CENTER;
      var pixbuf = DrawingService.load_icon (icon_name, int.max (32, width), int.max (32, height));
      Gtk.Image image;
      if (pixbuf != null)
        image = new Gtk.Image.from_pixbuf (pixbuf);
      else
        image = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.DIALOG);
      var label = new Gtk.Label (display);
      label.max_width_chars = 12;
      label.ellipsize = Pango.EllipsizeMode.END;
      label.justify = Gtk.Justification.CENTER;
      label.xalign = 0.5f;
      box.pack_start (image, false, false, 0);
      box.pack_start (label, false, false, 0);
      alignment.add (box);
      button.add (alignment);

      var launcher_copy = member_uri;
      button.clicked.connect (() => {
        popup_launching = true;
        launch_member (launcher_copy);
        if (!launcher_copy.has_prefix (URI_PREFIX))
          hide_popup ();
        popup_launching = false;
      });

      var target_list = new Gtk.TargetList (null);
      target_list.add_uri_targets (0);
      Gtk.drag_source_set (button, Gdk.ModifierType.BUTTON1_MASK, null, Gdk.DragAction.COPY);
      Gtk.drag_source_set_target_list (button, target_list);
      button.drag_data_get.connect ((ctx, selection_data, info, time_) => {
        string drag_uri = encode_member_drag_uri (owner_folder_uri, launcher_copy);
        string data = "%s\r\n".printf (drag_uri);
        selection_data.set (selection_data.get_target (), 8, (uchar[]) data.to_utf8 ());
      });

      return button;
    }

    private void toggle_popup () {
      if (popup_visible)
        hide_popup ();
      else
        show_popup ();
    }

    private void show_popup () {
      DockController? controller = get_dock ();
      if (controller == null)
        return;

      popup_current_folder_uri = Launcher;
      popup_navigation_stack.clear ();
      rebuild_popup ();
      if (popup_window == null)
        return;

      popup_window.show_all ();
      Gtk.Requisition req;
      popup_window.get_preferred_size (null, out req);

      int x, y;
      controller.position_manager.get_menu_position (this, req, out x, out y);
      popup_window.move (x, y);
      popup_window.present_with_time (Gdk.CURRENT_TIME);
      popup_visible = true;

      if (popup_focus_watch_id > 0) {
        Source.remove (popup_focus_watch_id);
        popup_focus_watch_id = 0;
      }

      // Ensure focus is actually moved to the popup, then keep watching focus.
      Timeout.add (50, () => {
        if (popup_window != null && popup_window.get_window () != null) {
          popup_window.get_window ().focus (Gdk.CURRENT_TIME);
          popup_window.get_window ().raise ();
        }
        return false;
      });

      popup_focus_watch_id = Timeout.add (200, () => {
        if (!popup_visible || popup_window == null)
          return false;

        if (!popup_window.has_toplevel_focus && !popup_launching) {
          hide_popup ();
          return false;
        }

        return true;
      });
    }

    private void hide_popup () {
      if (popup_focus_watch_id > 0) {
        Source.remove (popup_focus_watch_id);
        popup_focus_watch_id = 0;
      }

      if (popup_window != null)
        popup_window.hide ();
      popup_visible = false;
      popup_current_folder_uri = Launcher;
      popup_navigation_stack.clear ();
    }

    private void open_nested_folder (string folder_uri) {
      if (folder_uri == popup_current_folder_uri)
        return;

      popup_navigation_stack.add (popup_current_folder_uri);
      popup_current_folder_uri = folder_uri;
      rebuild_popup ();
    }

    private Gee.ArrayList<string> members_for_folder_uri (string folder_uri) {
      if (folder_uri == Launcher || folder_uri == "")
        return get_members ();

      string title;
      Gee.ArrayList<string> members;
      if (read_folder_metadata (folder_uri, out title, out members))
        return members;

      return new Gee.ArrayList<string> ();
    }

    private string folder_title_for_uri (string folder_uri) {
      if (folder_uri == Launcher) {
        var own_title = Prefs.FolderTitle.strip ();
        if (own_title != "")
          return own_title;
        return _("Folder");
      }

      string title;
      Gee.ArrayList<string> members;
      if (read_folder_metadata (folder_uri, out title, out members)) {
        var clean = title.strip ();
        if (clean != "")
          return clean;
      }

      return _("Folder");
    }

    private bool read_folder_metadata (string folder_uri, out string title, out Gee.ArrayList<string> members) {
      title = "";
      members = new Gee.ArrayList<string> ();

      DockController? controller = get_dock ();
      if (controller == null)
        return false;

      try {
        var enumerator = controller.launchers_folder.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
        FileInfo? info;
        while ((info = enumerator.next_file ()) != null) {
          var name = info.get_name ();
          if (name == null || !name.has_suffix (".dockitem"))
            continue;

          var file = controller.launchers_folder.get_child (name);
          try {
            var key = new KeyFile ();
            key.load_from_file (file.get_path (), 0);
            if (!key.has_key (typeof (DockItemPreferences).name (), "Launcher"))
              continue;

            var launcher = key.get_string (typeof (DockItemPreferences).name (), "Launcher");
            if (launcher != folder_uri)
              continue;

            if (key.has_key (typeof (DockItemPreferences).name (), "FolderTitle"))
              title = key.get_string (typeof (DockItemPreferences).name (), "FolderTitle");
            if (key.has_key (typeof (DockItemPreferences).name (), "FolderMembers")) {
              var serialized = key.get_string (typeof (DockItemPreferences).name (), "FolderMembers");
              members = parse_members (serialized);
            }

            return true;
          } catch {}
        }
      } catch {}

      return false;
    }

    private string build_auto_title (Gee.ArrayList<string> members) {
      if (members.size == 0)
        return _("Folder");

      if (members.size == 1)
        return shorten_title (member_display_name (members[0]), 28);

      var names = new Gee.ArrayList<string> ();
      int docklet_count = 0;
      int desktop_count = 0;
      int file_count = 0;

      foreach (var member in members) {
        names.add (member_display_name (member));

        if (member.has_prefix (DOCKLET_URI_PREFIX))
          docklet_count++;
        else if (member.has_suffix (".desktop"))
          desktop_count++;
        else
          file_count++;
      }

      if (members.size == 2)
        return shorten_title ("%s + %s".printf (names[0], names[1]), 36);

      var category_title = infer_category_title (members);
      if (category_title != "")
        return category_title;

      if (docklet_count == members.size)
        return _("Docklets");
      if (desktop_count == members.size)
        return _("Apps");
      if (file_count == members.size)
        return _("Files");

      return shorten_title (_("%s + %d").printf (names[0], members.size - 1), 36);
    }

    private string shorten_title (string title, int max_chars) {
      var clean = title.strip ();
      if (clean == "")
        return _("Folder");
      if (clean.length <= max_chars)
        return clean;

      return "%s...".printf (clean.substring (0, max_chars - 3));
    }

    private string infer_category_title (Gee.ArrayList<string> members) {
      var category_counts = new Gee.HashMap<string, int> ();
      int desktop_members = 0;

      foreach (var member in members) {
        if (!member.has_suffix (".desktop"))
          continue;

        desktop_members++;
        var category = read_primary_desktop_category (member);
        if (category == "")
          continue;

        int current = 0;
        if (category_counts.has_key (category))
          current = category_counts[category];
        category_counts[category] = current + 1;
      }

      if (desktop_members < 2)
        return "";

      foreach (var entry in category_counts.entries) {
        if (entry.value == desktop_members)
          return entry.key;
      }

      return "";
    }

    private string read_primary_desktop_category (string launcher_uri) {
      try {
        var key = new KeyFile ();
        key.load_from_file (Filename.from_uri (launcher_uri), 0);
        if (!key.has_key (KeyFileDesktop.GROUP, KeyFileDesktop.KEY_CATEGORIES))
          return "";

        foreach (unowned string raw in key.get_string_list (KeyFileDesktop.GROUP, KeyFileDesktop.KEY_CATEGORIES)) {
          var category = map_category_to_title (raw.strip ());
          if (category != "")
            return category;
        }
      } catch {}

      return "";
    }

    private string map_category_to_title (string category) {
      switch (category) {
      case "Audio":
      case "AudioVideo":
      case "Music":
      case "Player":
        return _("Media");
      case "Video":
        return _("Video");
      case "Development":
      case "IDE":
      case "Debugger":
        return _("Development");
      case "Game":
        return _("Games");
      case "Graphics":
      case "Photography":
        return _("Graphics");
      case "Network":
      case "WebBrowser":
      case "Email":
        return _("Internet");
      case "Office":
      case "Spreadsheet":
      case "Presentation":
      case "WordProcessor":
        return _("Office");
      case "Science":
        return _("Science");
      case "System":
      case "Settings":
      case "Utility":
      case "Monitor":
        return _("System");
      default:
        return "";
      }
    }
  }
}
