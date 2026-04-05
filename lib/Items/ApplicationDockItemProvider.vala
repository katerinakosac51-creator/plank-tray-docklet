//
// Copyright (C) 2011-2013 Robert Dyer, Rico Tzschichholz
//
// This file is part of Plank.
//
// Plank is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Plank is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank {
  /**
   * A container and controller class for managing application dock items on a dock.
   */
  public class ApplicationDockItemProvider : DockItemProvider, UnityClient {
    public signal void item_window_added (ApplicationDockItem item);

    public File LaunchersDir { get; construct; }

    FileMonitor? items_monitor = null;
    bool delay_items_monitor_handle = false;
    Gee.ArrayList<GLib.File> queued_files;

    /**
     * Creates a new container for dock items.
     *
     * @param launchers_dir the directory where to load/save .dockitems files from/to
     */
    public ApplicationDockItemProvider (File launchers_dir) {
      Object (LaunchersDir : launchers_dir);
    }

    construct
    {
      queued_files = new Gee.ArrayList<GLib.File> ();

      // Make sure our launchers-directory exists
      Paths.ensure_directory_exists (LaunchersDir);

      Matcher.get_default ().application_opened.connect (app_opened);

      try {
        items_monitor = LaunchersDir.monitor_directory (0);
        items_monitor.changed.connect (handle_items_dir_changed);
      } catch (Error e) {
        critical ("Unable to watch the launchers directory. (%s)", e.message);
      }
    }

    ~ApplicationDockItemProvider () {
      queued_files = null;

      Matcher.get_default ().application_opened.disconnect (app_opened);

      if (items_monitor != null) {
        items_monitor.changed.disconnect (handle_items_dir_changed);
        items_monitor.cancel ();
        items_monitor = null;
      }
    }

    protected unowned ApplicationDockItem ? item_for_application (Bamf.Application app) {
      var app_desktop_file = app.get_desktop_file ();
      if (app_desktop_file != null && app_desktop_file.has_prefix ("/"))
        try {
          app_desktop_file = Filename.to_uri (app_desktop_file);
        } catch (ConvertError e) {
          warning (e.message);
        }

      foreach (var item in internal_elements) {
        unowned ApplicationDockItem? appitem = (item as ApplicationDockItem);
        if (appitem == null)
          continue;

        unowned Bamf.Application? item_app = appitem.App;
        if (item_app != null && item_app == app)
          return appitem;

        unowned string launcher = appitem.Launcher;
        if (launcher != "" && app_desktop_file != null && launcher == app_desktop_file)
          return appitem;
      }

      return null;
    }

    static File ? desktop_file_for_application_uri (string app_uri) {
      foreach (var folder in Paths.DataDirFolders) {
        var applications_folder = folder.get_child ("applications");
        if (!applications_folder.query_exists ())
          continue;

        var desktop_file = applications_folder.get_child (app_uri.replace ("application://", ""));
        if (!desktop_file.query_exists ())
          continue;

        return desktop_file;
      }

      debug ("Matching application for '%s' not found or not installed!", app_uri);

      return null;
    }

    bool is_groupable_item (DockItem item) {
      if (item is FolderDockItem)
        return true;
      if (item is FileDockItem)
        return true;
      if (item is DockletItem)
        return normalized_item_launcher (item) != "";

      unowned ApplicationDockItem? app_item = (item as ApplicationDockItem);
      if (app_item == null)
        return false;

      return normalized_item_launcher (item) != "";
    }

    string normalize_launcher_uri (string uri) {
      if (uri == null || uri == "")
        return "";
      if (uri.has_prefix ("file://") || uri.has_prefix ("application://")
          || uri.has_prefix (DOCKLET_URI_PREFIX)
          || uri.has_prefix (FolderDockItem.URI_PREFIX)
          || uri.contains ("://"))
        return uri;
      if (uri.has_prefix ("/")) {
        try {
          return Filename.to_uri (uri);
        } catch (ConvertError e) {
          warning (e.message);
        }
      }
      return uri;
    }

    string normalized_item_launcher (DockItem item) {
      if (item is FolderDockItem)
        return item.Launcher;
      return normalize_launcher_uri (item.Launcher);
    }

    void remove_grouped_source_item (DockItem item) {
      remove (item);
      // Keep folder .dockitem files when nested so their metadata survives.
      if (item.DockItemFilename != "" && !(item is FolderDockItem))
        item.delete ();
    }

    File? find_existing_dockitem_file_for_launcher (string launcher_uri) {
      try {
        var enumerator = LaunchersDir.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
        FileInfo? info;
        while ((info = enumerator.next_file ()) != null) {
          var name = info.get_name ();
          if (name == null || !name.has_suffix (".dockitem"))
            continue;

          var file = LaunchersDir.get_child (name);
          try {
            var key = new KeyFile ();
            key.load_from_file (file.get_path (), 0);
            if (!key.has_key (typeof (DockItemPreferences).name (), "Launcher"))
              continue;

            var existing = key.get_string (typeof (DockItemPreferences).name (), "Launcher");
            if (existing == launcher_uri)
              return file;
          } catch {}
        }
      } catch {}

      return null;
    }

    bool get_folder_members_for_uri (string folder_uri, out Gee.ArrayList<string> members) {
      members = new Gee.ArrayList<string> ();

      unowned FolderDockItem? live_folder = folder_for_uri (folder_uri);
      if (live_folder != null) {
        members = live_folder.get_members ();
        return true;
      }

      var file = find_existing_dockitem_file_for_launcher (folder_uri);
      if (file == null)
        return false;

      try {
        var key = new KeyFile ();
        key.load_from_file (file.get_path (), 0);
        if (!key.has_key (typeof (DockItemPreferences).name (), "FolderMembers"))
          return true;

        var serialized = key.get_string (typeof (DockItemPreferences).name (), "FolderMembers");
        members = FolderDockItem.parse_members (serialized);
        return true;
      } catch {}

      return false;
    }

    bool folder_contains_member_recursive (string folder_uri, string member_uri, Gee.HashSet<string>? visited = null) {
      Gee.HashSet<string> seen = (visited != null) ? visited : new Gee.HashSet<string> ();

      if (seen.contains (folder_uri))
        return false;
      seen.add (folder_uri);

      Gee.ArrayList<string> members;
      if (!get_folder_members_for_uri (folder_uri, out members))
        return false;

      foreach (var member in members) {
        if (member == member_uri)
          return true;

        if (FolderDockItem.is_folder_uri (member)
            && folder_contains_member_recursive (member, member_uri, seen))
          return true;
      }

      return false;
    }

    unowned FolderDockItem? folder_for_uri (string folder_uri) {
      foreach (var element in internal_elements) {
        unowned FolderDockItem? folder = (element as FolderDockItem);
        if (folder != null && folder.Launcher == folder_uri)
          return folder;
      }
      return null;
    }

    bool resolve_drop_uri (string uri, out string resolved_uri, out string? source_folder_uri) {
      resolved_uri = uri;
      source_folder_uri = null;

      string folder_uri;
      string member_uri;
      if (FolderDockItem.decode_member_drag_uri (uri, out folder_uri, out member_uri)) {
        resolved_uri = member_uri;
        source_folder_uri = folder_uri;
      }

      return true;
    }

    bool contains_internal_uri (string uri) {
      foreach (var element in internal_elements) {
        unowned DockItem? item = (element as DockItem);
        if (item != null && item.Launcher == uri)
          return true;
      }
      return false;
    }

    void cleanup_folder_after_change (FolderDockItem folder) {
      int count = folder.get_member_count ();
      if (count > 1)
        return;

      delay_items_monitor ();

      if (count <= 0) {
        remove (folder);
        folder.delete ();
        resume_items_monitor ();
        return;
      }

      var remaining = folder.get_single_remaining_member ();
      if (remaining == null || remaining == "") {
        remove (folder);
        folder.delete ();
        resume_items_monitor ();
        return;
      }

      File? replacement_file = find_existing_dockitem_file_for_launcher (remaining);
      if (replacement_file == null)
        replacement_file = Factory.item_factory.make_dock_item (remaining, LaunchersDir);
      if (replacement_file == null) {
        resume_items_monitor ();
        return;
      }

      var replacement_element = Factory.item_factory.make_element (replacement_file);
      unowned DockItem? replacement = (replacement_element as DockItem);
      if (replacement == null) {
        resume_items_monitor ();
        return;
      }

      replace (replacement, folder);
      folder.delete ();
      resume_items_monitor ();
    }

    public bool remove_member_from_folder (string folder_uri, string member_uri) {
      unowned FolderDockItem? folder = folder_for_uri (folder_uri);
      if (folder == null)
        return false;

      var members = folder.get_members ();
      int index_to_remove = -1;
      var normalized_member = normalize_launcher_uri (member_uri);

      for (int i = 0; i < members.size; i++) {
        var candidate = members[i];
        if (candidate == member_uri) {
          index_to_remove = i;
          break;
        }

        var normalized_candidate = normalize_launcher_uri (candidate);
        if (normalized_candidate != "" && normalized_candidate == normalized_member) {
          index_to_remove = i;
          break;
        }
      }

      if (index_to_remove < 0)
        return false;

      members.remove_at (index_to_remove);
      folder.set_members (members);
      cleanup_folder_after_change (folder);
      return true;
    }

    public bool try_group_items (DockItem source, DockItem target) {
      if (!internal_elements.contains (source) || !internal_elements.contains (target))
        return false;
      if (source == target)
        return false;

      if (!is_groupable_item (source) || !is_groupable_item (target))
        return false;

      unowned FolderDockItem? source_folder = (source as FolderDockItem);
      unowned FolderDockItem? target_folder = (target as FolderDockItem);

      if (target_folder != null) {
        var source_uri = normalized_item_launcher (source);
        if (source_uri == "")
          return false;

        if (source_folder != null) {
          if (source_folder.Launcher == target_folder.Launcher)
            return false;

          // Prevent recursive cycles like A -> ... -> B and then B contains A.
          if (folder_contains_member_recursive (source_folder.Launcher, target_folder.Launcher))
            return false;
        }

        if (target_folder.add_member (source_uri)) {
          delay_items_monitor ();
          remove_grouped_source_item (source);
          cleanup_folder_after_change (target_folder);
          resume_items_monitor ();
          return true;
        }
        return false;
      }

      if (source_folder != null) {
        var target_uri = normalized_item_launcher (target);
        if (target_uri == "")
          return false;

        if (source_folder.add_member (target_uri)) {
          delay_items_monitor ();
          remove_grouped_source_item (target);
          cleanup_folder_after_change (source_folder);
          resume_items_monitor ();
          return true;
        }
        return false;
      }

      delay_items_monitor ();

      var folder_uri = FolderDockItem.make_folder_uri ();
      var folder_file = Factory.item_factory.make_dock_item (folder_uri, LaunchersDir);
      if (folder_file == null) {
        resume_items_monitor ();
        return false;
      }

      var folder_element = Factory.item_factory.make_element (folder_file);
      unowned FolderDockItem? folder_item = (folder_element as FolderDockItem);
      if (folder_item == null) {
        resume_items_monitor ();
        return false;
      }

      var source_uri = normalized_item_launcher (source);
      var target_uri = normalized_item_launcher (target);
      if (source_uri == "" || target_uri == "") {
        resume_items_monitor ();
        return false;
      }

      var members = new Gee.ArrayList<string> ();
      members.add (target_uri);
      members.add (source_uri);
      folder_item.set_members (members);

      add (folder_item, target);
      remove_grouped_source_item (source);
      remove_grouped_source_item (target);

      resume_items_monitor ();
      return true;
    }

    /**
     * {@inheritDoc}
     */
    public override bool add_item_with_uri (string uri, DockItem? target = null) {
      if (uri == null || uri == "")
        return false;

      if (target != null && target != placeholder_item && !internal_elements.contains (target)) {
        critical ("Item '%s' does not exist in this DockItemProvider.", target.Text);
        return false;
      }

      string resolved_uri;
      string? source_folder_uri;
      resolve_drop_uri (uri, out resolved_uri, out source_folder_uri);
      var original_member_uri = resolved_uri;
      resolved_uri = normalize_launcher_uri (resolved_uri);

      if (contains_internal_uri (resolved_uri) && !allow_duplicate_item (resolved_uri)) {
        warning ("Item for '%s' already exists in this DockItemProvider.", resolved_uri);
        return false;
      }

      // delay automatic add of new dockitems while creating this new one
      delay_items_monitor ();

      File? dockitem_file = allow_duplicate_item (resolved_uri)
        ? null
        : find_existing_dockitem_file_for_launcher (resolved_uri);
      if (dockitem_file == null)
        dockitem_file = Factory.item_factory.make_dock_item (resolved_uri, LaunchersDir);
      if (dockitem_file == null) {
        resume_items_monitor ();
        return false;
      }

      var element = Factory.item_factory.make_element (dockitem_file);
      unowned DockItem? item = (element as DockItem);
      if (item == null) {
        resume_items_monitor ();
        return false;
      }

      add (item, target);

      if (source_folder_uri != null) {
        // Remove using the original member payload form to avoid URI/path
        // normalization mismatches with older folder entries.
        if (!remove_member_from_folder (source_folder_uri, original_member_uri))
          remove_member_from_folder (source_folder_uri, resolved_uri);
      }

      resume_items_monitor ();

      return true;
    }

    public override bool can_accept_drop (Gee.ArrayList<string> uris) {
      foreach (var raw in uris) {
        string uri;
        string? source_folder_uri;
        resolve_drop_uri (raw, out uri, out source_folder_uri);

        if (!contains_internal_uri (uri) || allow_duplicate_item (uri))
          return true;
      }
      return false;
    }

    public override bool accept_drop (Gee.ArrayList<string> uris) {
      bool result = false;

      unowned DockItem? target_item = null;
      unowned DockController? controller = get_dock ();
      if (controller != null && controller.window.HoveredItemProvider == this) {
        target_item = controller.position_manager.get_current_target_item (this);
      }

      foreach (var raw in uris) {
        string uri;
        string? source_folder_uri;
        resolve_drop_uri (raw, out uri, out source_folder_uri);

        if (!contains_internal_uri (uri) || allow_duplicate_item (uri)) {
          if (add_item_with_uri (raw, target_item))
            result = true;
        }
      }

      return result;
    }

    /**
     * {@inheritDoc}
     */
    public override void prepare () {
      // Match running applications to their available dock-items
      foreach (var app in Matcher.get_default ().active_launchers ()) {
        unowned ApplicationDockItem? found = item_for_application (app);
        if (found != null)
          found.App = app;
      }
    }

    /**
     * {@inheritDoc}
     */
    public override string[] get_dockitem_filenames () {
      var item_list = new Gee.ArrayList<string> ();

      foreach (var element in internal_elements) {
        unowned DockItem? item = (element as DockItem);
        if (item == null || (item is TransientDockItem))
          continue;

        var dock_item_filename = item.DockItemFilename;
        if (dock_item_filename.length > 0) {
          item_list.add ((owned) dock_item_filename);
        }
      }

      return item_list.to_array ();
    }

    protected virtual void app_opened (Bamf.Application app) {
      // Make sure internal window-list of Wnck is most up to date
      Wnck.Screen.get_default ().force_update ();

      unowned ApplicationDockItem? found = item_for_application (app);
      if (found != null)
        found.App = app;
    }

    protected void delay_items_monitor () {
      delay_items_monitor_handle = true;
    }

    protected void resume_items_monitor () {
      delay_items_monitor_handle = false;
      process_queued_files ();
    }

    void process_queued_files () {
      foreach (var file in queued_files) {
        var basename = file.get_basename ();
        bool skip = false;
        foreach (var element in internal_elements) {
          unowned DockItem? item = (element as DockItem);
          if (item != null && basename == item.DockItemFilename) {
            skip = true;
            break;
          }
        }

        if (skip)
          continue;

        Logger.verbose ("ApplicationDockItemProvider.process_queued_files ('%s')", basename);
        var element = Factory.item_factory.make_element (file);
        unowned DockItem? item = (element as DockItem);
        if (item == null)
          continue;

        unowned DockItem? dupe;
        if ((dupe = item_for_uri (item.Launcher)) != null) {
          warning ("The launcher '%s' in dock item '%s' is already managed by dock item '%s'. Removing '%s'.",
                   item.Launcher, file.get_path (), dupe.DockItemFilename, item.DockItemFilename);
          item.delete ();
        } else if (!item.is_valid ()) {
          warning ("The launcher '%s' in dock item '%s' does not exist. Removing '%s'.", item.Launcher, file.get_path (), item.DockItemFilename);
          item.delete ();
        } else {
          add (item);
        }
      }

      queued_files.clear ();
    }

    [CCode (instance_pos = -1)]
    void handle_items_dir_changed (File f, File? other, FileMonitorEvent event) {
      // only watch for new items, existing ones watch themselves for updates or deletions
      if (event != FileMonitorEvent.CREATED)
        return;

      if (!file_is_dockitem (f))
        return;

      // bail if an item already manages this dockitem-file
      foreach (var element in internal_elements) {
        unowned DockItem? item = (element as DockItem);
        if (item != null && f.get_basename () == item.DockItemFilename)
          return;
      }

      Logger.verbose ("ApplicationDockItemProvider.handle_items_dir_changed (processing '%s')", f.get_path ());

      queued_files.add (f);

      if (!delay_items_monitor_handle)
        process_queued_files ();
    }

    protected override void connect_element (DockElement element) {
      base.connect_element (element);

      unowned ApplicationDockItem? appitem = (element as ApplicationDockItem);
      if (appitem != null) {
        appitem.app_window_added.connect (handle_item_app_window_added);
      }
    }

    protected override void disconnect_element (DockElement element) {
      base.disconnect_element (element);

      unowned ApplicationDockItem? appitem = (element as ApplicationDockItem);
      if (appitem != null) {
        appitem.app_window_added.disconnect (handle_item_app_window_added);
      }
    }

    void handle_item_app_window_added (ApplicationDockItem item) {
      item_window_added (item);
    }

    public void remove_launcher_entry (string sender_name) {
      // Reset item since there is no new NameOwner
      foreach (var item in internal_elements) {
        unowned ApplicationDockItem? app_item = item as ApplicationDockItem;
        if (app_item == null)
          continue;

        if (app_item.get_unity_dbusname () != sender_name)
          continue;

        app_item.unity_reset ();

        // Remove item which only exists because of the presence of
        // this removed LauncherEntry interface
        unowned TransientDockItem? transient_item = item as TransientDockItem;
        if (transient_item != null && transient_item.App == null)
          remove (transient_item);

        break;
      }
    }

    public void update_launcher_entry (string sender_name, Variant parameters, bool is_retry = false) {
      string app_uri;
      VariantIter prop_iter;
      parameters.get ("(sa{sv})", out app_uri, out prop_iter);

      Logger.verbose ("Unity.handle_update_request (processing update for %s)", app_uri);

      ApplicationDockItem? current_item = null, alternate_item = null;
      foreach (var item in internal_elements) {
        unowned ApplicationDockItem? app_item = item as ApplicationDockItem;
        if (app_item == null)
          continue;

        // Prefer matching application-uri of available items
        if (app_item.get_unity_application_uri () == app_uri) {
          current_item = app_item;
          break;
        }

        if (app_item.get_unity_dbusname () == sender_name)
          alternate_item = app_item;
      }

      // Fallback to matching dbus-sender-name
      if (current_item == null)
        current_item = alternate_item;

      // Update our entry and trigger a redraw
      if (current_item != null) {
        current_item.unity_update (sender_name, prop_iter);

        // Remove item which progress-bar/badge is gone and only existed
        // because of the presence of this LauncherEntry interface
        unowned TransientDockItem? transient_item = current_item as TransientDockItem;
        if (transient_item != null && transient_item.App == null
            && !(transient_item.has_unity_info ()))
          remove (transient_item);

        return;
      }

      if (!is_retry) {
        // Wait to let further update requests come in to catch the case where one application
        // sends out multiple LauncherEntry-updates with different application-uris, e.g. Nautilus
        Idle.add (() => {
          update_launcher_entry (sender_name, parameters, true);
          return false;
        });

        return;
      }

      unowned DefaultApplicationDockItemProvider? provider = (this as DefaultApplicationDockItemProvider);
      if (provider != null && !provider.Prefs.PinnedOnly) {
        // Find a matching desktop-file and create new TransientDockItem for this LauncherEntry
        var desktop_file = desktop_file_for_application_uri (app_uri);
        if (desktop_file != null) {
          current_item = new TransientDockItem.with_launcher (desktop_file.get_uri ());
          current_item.unity_update (sender_name, prop_iter);

          // Only add item if there is actually a visible progress-bar or badge
          // or the backing application provides a quicklist-dbusmenu
          if (current_item.has_unity_info ())
            add (current_item);
        }

        if (current_item == null)
          warning ("Matching application for '%s' not found or not installed!", app_uri);
      }
    }
  }
}
