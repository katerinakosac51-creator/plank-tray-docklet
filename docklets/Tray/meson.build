docklet_tray_sources = [
  'TrayDockItem.vala',
  'TrayDocklet.vala',
]

docklet_tray_resources = gnome.compile_resources(
  'docky-tray-resources',
  'tray.gresource.xml',
  c_name: 'docky_tray',
)

shared_module(
  'docklet-tray',
  docklet_tray_sources,
  docklet_tray_resources,
  dependencies: [plank_dep, plank_base_dep],
  install: true,
  install_dir: docklets_dir,
)
