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

[DBus (name = "org.mpris.MediaPlayer2.Player")]
interface MprisPlayer : Object {
  public abstract string playback_status { owned get; }
  public abstract HashTable<string, Variant> metadata { owned get; }
  public abstract void play_pause () throws Error;
  public abstract void next () throws Error;
  public abstract void previous () throws Error;
  public abstract void play () throws Error;
  public abstract void pause () throws Error;
  public abstract void stop () throws Error;
}

[DBus (name = "org.freedesktop.DBus")]
interface DBusNameList : Object {
  public abstract string[] list_names () throws Error;
}

[DBus (name = "org.freedesktop.DBus.Properties")]
interface DBusProperties : Object {
  public signal void properties_changed (string iface, HashTable<string, Variant> changed,
                                          string[] invalidated);
}

namespace Docky {
  public class NowPlayingDockItem : DockletItem {

    private MprisPlayer? player = null;
    private DBusProperties? props_proxy = null;
    private DBusNameList? dbus_list = null;
    private ulong props_handler_id = 0;
    private uint poll_timer_id = 0;

    private string current_title = "";
    private string current_artist = "";
    private string current_album = "";
    private string current_art_url = "";
    private string current_status = "Stopped";
    private string current_player_bus = "";

    private Gdk.Pixbuf? album_art_pixbuf = null;
    private Gtk.Menu? menu_widget = null;

    public NowPlayingDockItem.with_dockitem_file (GLib.File file)
    {
      GLib.Object (Prefs : new DockItemPreferences.with_file (file));
    }

    construct
    {
      Icon = NowPlayingDocklet.ICON;
      Text = _("No media playing");

      find_player.begin ();

      // Poll for new players every 5 seconds
      poll_timer_id = Timeout.add_seconds (5, () => {
        if (player == null)
          find_player.begin ();
        return true;
      });
    }

    ~NowPlayingDockItem () {
      if (poll_timer_id > 0) {
        Source.remove (poll_timer_id);
        poll_timer_id = 0;
      }

      disconnect_player ();

      if (menu_widget != null) {
        menu_widget.show.disconnect (on_menu_show);
        menu_widget.hide.disconnect (on_menu_hide);
        menu_widget = null;
      }
    }

    private void disconnect_player () {
      if (props_proxy != null && props_handler_id > 0) {
        props_proxy.disconnect (props_handler_id);
        props_handler_id = 0;
      }
      props_proxy = null;
      player = null;
      current_player_bus = "";
    }

    private async void find_player () {
      try {
        if (dbus_list == null) {
          dbus_list = yield Bus.get_proxy (BusType.SESSION,
            "org.freedesktop.DBus", "/org/freedesktop/DBus");
        }

        var names = dbus_list.list_names ();
        foreach (unowned string name in names) {
          if (name.has_prefix ("org.mpris.MediaPlayer2.")) {
            yield connect_to_player (name);
            return;
          }
        }
      } catch (Error e) {
        warning ("Failed to find MPRIS player: %s", e.message);
      }
    }

    private async void connect_to_player (string bus_name) {
      disconnect_player ();
      current_player_bus = bus_name;

      try {
        player = yield Bus.get_proxy (BusType.SESSION,
          bus_name, "/org/mpris/MediaPlayer2");

        props_proxy = yield Bus.get_proxy (BusType.SESSION,
          bus_name, "/org/mpris/MediaPlayer2");

        props_handler_id = props_proxy.properties_changed.connect (
          (iface, changed, invalidated) => {
            if (iface == "org.mpris.MediaPlayer2.Player")
              update_metadata ();
          }
        );

        update_metadata ();
      } catch (Error e) {
        warning ("Failed to connect to player %s: %s", bus_name, e.message);
        player = null;
      }
    }

    private void update_metadata () {
      if (player == null)
        return;

      try {
        current_status = player.playback_status ?? "Stopped";
      } catch {
        current_status = "Stopped";
      }

      try {
        var meta = player.metadata;
        if (meta != null) {
          var title_var = meta.lookup ("xesam:title");
          current_title = (title_var != null) ? title_var.get_string () : "";

          var artist_var = meta.lookup ("xesam:artist");
          if (artist_var != null) {
            // Artist can be a string array
            if (artist_var.is_of_type (VariantType.STRING_ARRAY)) {
              var artists = artist_var.get_strv ();
              current_artist = string.joinv (", ", artists);
            } else if (artist_var.is_of_type (VariantType.STRING)) {
              current_artist = artist_var.get_string ();
            } else {
              current_artist = "";
            }
          } else {
            current_artist = "";
          }

          var album_var = meta.lookup ("xesam:album");
          current_album = (album_var != null) ? album_var.get_string () : "";

          var art_var = meta.lookup ("mpris:artUrl");
          var new_art_url = (art_var != null) ? art_var.get_string () : "";

          if (new_art_url != current_art_url) {
            current_art_url = new_art_url;
            load_album_art.begin ();
          }
        }
      } catch {
        // Metadata read failed, keep previous values
      }

      // Update tooltip
      if (current_title != "") {
        if (current_artist != "")
          Text = "%s — %s".printf (current_title, current_artist);
        else
          Text = current_title;
      } else {
        Text = _("No media playing");
      }

      // Update icon based on playback state
      if (current_status == "Playing")
        Icon = "media-playback-start;;audio-x-generic";
      else if (current_status == "Paused")
        Icon = "media-playback-pause;;audio-x-generic";
      else
        Icon = NowPlayingDocklet.ICON;

      // If album art is loaded, use it
      if (album_art_pixbuf != null)
        ForcePixbuf = album_art_pixbuf;
      else
        ForcePixbuf = null;

      build_menu ();
    }

    private async void load_album_art () {
      album_art_pixbuf = null;

      if (current_art_url == "") {
        ForcePixbuf = null;
        return;
      }

      try {
        if (current_art_url.has_prefix ("file://")) {
          var path = Filename.from_uri (current_art_url);
          album_art_pixbuf = new Gdk.Pixbuf.from_file_at_scale (path, 128, 128, true);
        } else if (current_art_url.has_prefix ("http://") || current_art_url.has_prefix ("https://")) {
          // For HTTP URLs, download to temp and load
          var file = File.new_for_uri (current_art_url);
          var stream = yield file.read_async ();
          album_art_pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async (stream, 128, 128, true, null);
        }

        if (album_art_pixbuf != null)
          ForcePixbuf = album_art_pixbuf;
      } catch (Error e) {
        // Art loading failed, use default icon
        album_art_pixbuf = null;
        ForcePixbuf = null;
      }
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

      if (player == null) {
        var no_player = new Gtk.MenuItem.with_label (_("No media player found"));
        no_player.sensitive = false;
        no_player.show ();
        menu_widget.append (no_player);
        return;
      }

      // Track info header
      if (current_title != "") {
        var title_item = new Gtk.MenuItem.with_label (current_title);
        title_item.sensitive = false;
        title_item.show ();
        menu_widget.append (title_item);

        if (current_artist != "") {
          var artist_item = new Gtk.MenuItem.with_label (current_artist);
          artist_item.sensitive = false;
          artist_item.show ();
          menu_widget.append (artist_item);
        }

        if (current_album != "") {
          var album_item = new Gtk.MenuItem.with_label (current_album);
          album_item.sensitive = false;
          album_item.show ();
          menu_widget.append (album_item);
        }

        var sep = new Gtk.SeparatorMenuItem ();
        sep.show ();
        menu_widget.append (sep);
      }

      // Previous
      var prev_item = new Gtk.MenuItem.with_label ("\u23EE  " + _("Previous"));
      prev_item.activate.connect (() => {
        try { player.previous (); } catch {}
      });
      prev_item.show ();
      menu_widget.append (prev_item);

      // Play/Pause
      var pp_label = (current_status == "Playing") ?
        "\u23F8  " + _("Pause") :
        "\u25B6  " + _("Play");
      var pp_item = new Gtk.MenuItem.with_label (pp_label);
      pp_item.activate.connect (() => {
        try { player.play_pause (); } catch {}
      });
      pp_item.show ();
      menu_widget.append (pp_item);

      // Next
      var next_item = new Gtk.MenuItem.with_label ("\u23ED  " + _("Next"));
      next_item.activate.connect (() => {
        try { player.next (); } catch {}
      });
      next_item.show ();
      menu_widget.append (next_item);

      // Stop
      var sep2 = new Gtk.SeparatorMenuItem ();
      sep2.show ();
      menu_widget.append (sep2);

      var stop_item = new Gtk.MenuItem.with_label ("\u23F9  " + _("Stop"));
      stop_item.activate.connect (() => {
        try { player.stop (); } catch {}
      });
      stop_item.show ();
      menu_widget.append (stop_item);
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
      if (player == null)
        return AnimationType.NONE;

      try {
        if (direction == Gdk.ScrollDirection.UP || direction == Gdk.ScrollDirection.LEFT)
          player.previous ();
        else
          player.next ();
      } catch {}

      return AnimationType.NONE;
    }

    protected override AnimationType on_clicked (PopupButton button,
                                                  Gdk.ModifierType mod, uint32 event_time) {
      if ((button & PopupButton.LEFT) != 0) {
        update_metadata ();
        show_now_playing_menu ();
        return AnimationType.NONE;
      }

      return AnimationType.NONE;
    }

    private void show_now_playing_menu () {
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
