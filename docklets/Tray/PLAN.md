# Plan: System Tray Docklet for Plank Reloaded

## Context

Plank Reloaded doesn't show background/system tray apps (like Handy). No existing docklet does this. We'll build a **TrayDocklet** that shows system tray (StatusNotifierItem) icons on the dock, letting the user interact with tray apps directly from Plank.

## Approach

Build a docklet that acts as a [StatusNotifierHost](https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/) — it listens to the `org.kde.StatusNotifierWatcher` D-Bus service (already running on your system) to discover tray items, fetches their icons, and renders them in the dock.

## Architecture

**Two-part design:**
1. **Single docklet icon** on the dock showing a tray icon (e.g., system tray symbol)
2. **On click** — shows a popup menu listing all current tray items with their icons and names
3. **Clicking a tray item** — activates it (sends `Activate` D-Bus call to the app)

Alternatively (stretch): render each tray item as a separate visual element, but given the docklet architecture (one icon per docklet), the menu approach is simpler and consistent with the Applications docklet pattern.

## Files to Create

All under `~/plank-reloaded/docklets/Tray/`:

| File | Purpose |
|------|---------|
| `TrayDocklet.vala` | Plugin registration (implements `Plank.Docklet` interface) |
| `TrayDockItem.vala` | Main logic — D-Bus listener, icon rendering, menu building |
| `icons/system-tray.svg` | Docklet icon (simple tray icon SVG) |
| `tray.gresource.xml` | GResource bundle for the icon |
| `meson.build` | Build config |

## Files to Modify

| File | Change |
|------|--------|
| `~/plank-reloaded/docklets/meson.build` | Add `subdir('Tray')` |

## Implementation Details

### TrayDocklet.vala (~30 lines)
- Standard docklet registration pattern (same as Desktop docklet)
- `docklet_init()` entry point, implements `Plank.Docklet` interface
- ID: `"tray"`, Name: `"System Tray"`

### TrayDockItem.vala (~200-250 lines)
Core logic:

1. **D-Bus Integration:**
   - Connect to `org.kde.StatusNotifierWatcher` at `/StatusNotifierWatcher`
   - Call `RegisteredStatusNotifierItems` property to get list of tray item service names
   - Listen to `StatusNotifierItemRegistered` / `StatusNotifierItemUnregistered` signals for live updates

2. **Tray Item Discovery:**
   - For each registered item (e.g., `org.blueman.Tray`), query `org.kde.StatusNotifierItem` interface at its object path
   - Read properties: `IconName`, `Title`, `Menu` (for submenu path)
   - Cache icon pixbufs from `IconPixmap` property or load by `IconName` from theme

3. **Menu Display (on left-click):**
   - Build `Gtk.Menu` with one `Gtk.ImageMenuItem` per tray item
   - Show icon + title for each
   - On menu item click: call `Activate(x, y)` method on the item's D-Bus interface
   - Position menu using `controller.position_manager.get_menu_position()` (same pattern as Applications docklet)

4. **Right-click on a tray item submenu entry (stretch):**
   - Proxy the app's own D-Bus menu (`com.canonical.dbusmenu`) — complex, defer to v2

5. **Icon rendering:**
   - Use a static system-tray icon for the dock
   - Show badge count (`CountVisible` / `Count`) with number of active tray items

### D-Bus Interfaces Needed (Vala annotations)

```vala
[DBus (name = "org.kde.StatusNotifierWatcher")]
interface StatusNotifierWatcher : Object {
    public abstract string[] registered_status_notifier_items { owned get; }
    public signal void status_notifier_item_registered(string service);
    public signal void status_notifier_item_unregistered(string service);
}

[DBus (name = "org.kde.StatusNotifierItem")]
interface StatusNotifierItem : Object {
    public abstract string title { owned get; }
    public abstract string icon_name { owned get; }
    public abstract string status { owned get; }
    public abstract void activate(int x, int y) throws Error;
}
```

### meson.build
```meson
gnome = import('gnome')

tray_resources = gnome.compile_resources(
  'tray-resources', 'tray.gresource.xml',
  source_dir: '.',
)

docklet_tray_sources = [
  'TrayDockItem.vala',
  'TrayDocklet.vala',
]

shared_module(
  'docklet-tray',
  docklet_tray_sources,
  tray_resources,
  dependencies: [plank_dep, plank_base_dep],
  install: true,
  install_dir: docklets_dir,
)
```

## Key Patterns to Follow (from existing docklets)

- **Constructor**: `with_dockitem_file(GLib.File file)` passing `DockItemPreferences`
- **Signal cleanup**: Disconnect all D-Bus signals in destructor
- **Menu positioning**: Use `controller.position_manager.get_menu_position()`
- **Icon**: Use GResource URI `resource:///net/launchpad/plank/docklets/tray/icons/system-tray.svg`
- **Badge**: Set `Count` and `CountVisible` to show number of tray items

## Build & Test

```bash
cd ~/plank-reloaded
rm -rf build
meson setup build
ninja -C build
killall plank; sudo ninja -C build install && sudo ldconfig && plank &
```

Then: right-click dock > Preferences > Docklets > drag "System Tray" onto dock.

## Verification

1. Docklet appears in Plank preferences docklet list
2. Clicking it shows a menu with current tray apps (blueman, etc.)
3. Clicking a tray app in the menu activates/focuses it
4. Badge shows count of tray items
5. Adding/removing tray apps updates the menu dynamically
