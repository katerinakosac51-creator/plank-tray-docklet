# Plan: Recent Files Docklet

## Context

macOS dock supports recent items stacks. This docklet shows recently opened files via Gtk.RecentManager, with icons and one-click opening.

## Architecture

- **Dock icon**: A clock/file icon with badge showing count of recent files
- **Left-click**: Popup menu listing recent files (most recent first) with file icons
- **Click on file**: Opens with default app via `AppInfo.launch_default_for_uri()`
- **Right-click submenu per file**: Open, Open With..., Show in File Manager, Remove from Recent

## Files to Create

All under `docklets/RecentFiles/`:

| File | Purpose |
|------|---------|
| `RecentFilesDocklet.vala` | Plugin registration |
| `RecentFilesDockItem.vala` | Gtk.RecentManager integration, menu building |
| `RecentFilesPreferences.vala` | Settings: max items to show, file type filter |
| `icons/recent-files.svg` | Docklet icon |
| `recentfiles.gresource.xml` | GResource bundle |
| `meson.build` | Build config |

## Key Implementation Details

1. **Recent Files**: `Gtk.RecentManager.get_default().get_items()` — returns list of `Gtk.RecentInfo`
2. **Sorting**: Sort by `recent_info.get_modified()` descending (most recent first)
3. **Icons**: `recent_info.get_gicon()` for file type icons
4. **Live Updates**: `recent_manager.changed.connect()` signal to rebuild menu
5. **Preferences**: Max items (default 20), optional MIME type filter
6. **Menu items**: Show filename + parent directory, icon from MIME type
7. **Right-click submenu**: Open, Show in Files (`AppInfo.launch_default_for_uri` on parent dir), Remove from Recent (`recent_manager.remove_item(uri)`)

## Modify

- `docklets/meson.build` — add `subdir('RecentFiles')`
