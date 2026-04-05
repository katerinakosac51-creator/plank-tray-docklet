docklet_clippy_sources = [
  'ClippyDockItem.vala',
  'ClippyDocklet.vala',
  'ClippyPreferences.vala',
  'ClippyClipboardItem.vala',
]

docklet_clippy_resources = gnome.compile_resources(
  'docky-clippy-resources',
  'clippy.gresource.xml',
  c_name: 'docky_clippy',
)

shared_module(
  'docklet-clippy',
  docklet_clippy_sources,
  docklet_clippy_resources,
  dependencies: [plank_dep, plank_base_dep],
  install: true,
  install_dir: docklets_dir,
)
