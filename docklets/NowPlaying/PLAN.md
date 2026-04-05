# Plan: Now Playing (Media) Docklet

## Context

macOS dock shows a Now Playing widget. This docklet shows the currently playing track with album art on the dock icon, and a popup menu with playback controls. Uses MPRIS2 D-Bus — works with Spotify, Firefox, Brave, VLC, etc.

## Architecture

- **Dock icon**: Shows album art (or a music note fallback) rendered via `draw_icon()`
- **Tooltip**: Current track title and artist
- **Left-click**: Popup menu with track info + Play/Pause, Next, Previous
- **Scroll**: Volume or Next/Prev track

## Files to Create

All under `docklets/NowPlaying/`:

| File | Purpose |
|------|---------|
| `NowPlayingDocklet.vala` | Plugin registration |
| `NowPlayingDockItem.vala` | MPRIS2 D-Bus listener, custom icon drawing, menu |
| `icons/now-playing.svg` | Fallback music note icon |
| `nowplaying.gresource.xml` | GResource bundle |
| `meson.build` | Build config |

## D-Bus Interfaces

```vala
[DBus (name = "org.mpris.MediaPlayer2.Player")]
interface MprisPlayer : Object {
  public abstract string playback_status { owned get; }
  public abstract HashTable<string, Variant> metadata { owned get; }
  public abstract void play_pause () throws Error;
  public abstract void next () throws Error;
  public abstract void previous () throws Error;
}
```

## Key Implementation Details

1. **Player Discovery**: List D-Bus names matching `org.mpris.MediaPlayer2.*`, connect to first active one
2. **Metadata**: Read `xesam:title`, `xesam:artist`, `mpris:artUrl` from Metadata property
3. **Album Art**: Download/load art from `mpris:artUrl` (file:// or http://), render onto dock icon via `draw_icon()` override (pattern from Clock docklet)
4. **Live Updates**: Listen to `org.freedesktop.DBus.Properties.PropertiesChanged` signal
5. **Menu**: Track info header + Play/Pause, Next, Previous buttons
6. **Scroll**: on_scrolled() calls Next/Previous

## Modify

- `docklets/meson.build` — add `subdir('NowPlaying')`
