# Plan: Stacks Docklet

## Context

macOS dock has "Stacks" — clicking a folder icon fans/grids out its contents. This docklet monitors a user-configured folder (default ~/Downloads) and shows its contents in a popup menu, sorted by modification time.

## Architecture

- **Dock icon**: Folder icon with badge showing file count
- **Left-click**: Popup menu listing folder contents (newest first) with file type icons
- **Click on file**: Opens with default app
- **Right-click submenu per file**: Open, Show in File Manager, Move to Trash, Delete
- **Docklet right-click menu**: Change monitored folder, sort order, show/hide hidden files

## Files to Create

All under `docklets/Stacks/`:

| File | Purpose |
|------|---------|
| `StacksDocklet.vala` | Plugin registration |
| `StacksDockItem.vala` | GLib.FileMonitor, directory listing, menu |
| `StacksPreferences.vala` | Settings: folder path, sort order, show hidden, max items |
| `icons/stacks.svg` | Docklet icon |
| `stacks.gresource.xml` | GResource bundle |
| `meson.build` | Build config |

## Key Implementation Details

1. **Directory Monitoring**: `File.monitor_directory(0)` on configured folder — pattern from Trash docklet (`TrashDockItem.vala:67-75`)
2. **File Listing**: `File.enumerate_children()` with attributes: STANDARD_NAME, STANDARD_ICON, STANDARD_CONTENT_TYPE, STANDARD_IS_HIDDEN, TIME_MODIFIED
3. **Sorting**: By modification time (newest first), configurable to name/size
4. **Icons**: `DrawingService.get_icon_from_gicon(info.get_icon())` — same pattern as Applications docklet
5. **File Actions**:
   - Open: `AppInfo.launch_default_for_uri(file.get_uri())`
   - Show in Files: open parent directory URI
   - Move to Trash: `file.trash()`
   - Delete: `file.delete()`
6. **Preferences**:
   - `FolderPath` (string, default `~/Downloads`)
   - `SortBy` (enum: MODIFIED, NAME, SIZE)
   - `ShowHidden` (bool, default false)
   - `MaxItems` (int, default 30)
7. **Badge**: `Count` = number of files, `CountVisible` = true
8. **Monitor cleanup**: Disconnect and cancel in destructor (pattern from Trash docklet:85-88)

## Modify

- `docklets/meson.build` — add `subdir('Stacks')`
