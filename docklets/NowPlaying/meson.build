docklet_nowplaying_sources = [
  'NowPlayingDockItem.vala',
  'NowPlayingDocklet.vala',
]

docklet_nowplaying_resources = gnome.compile_resources(
  'docky-nowplaying-resources',
  'nowplaying.gresource.xml',
  c_name: 'docky_nowplaying',
)

shared_module(
  'docklet-nowplaying',
  docklet_nowplaying_sources,
  docklet_nowplaying_resources,
  dependencies: [plank_dep, plank_base_dep],
  install: true,
  install_dir: docklets_dir,
)
