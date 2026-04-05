docklet_recentfiles_sources = [
  'RecentFilesDockItem.vala',
  'RecentFilesDocklet.vala',
  'RecentFilesPreferences.vala',
]

docklet_recentfiles_resources = gnome.compile_resources(
  'docky-recentfiles-resources',
  'recentfiles.gresource.xml',
  c_name: 'docky_recentfiles',
)

shared_module(
  'docklet-recentfiles',
  docklet_recentfiles_sources,
  docklet_recentfiles_resources,
  dependencies: [plank_dep, plank_base_dep],
  install: true,
  install_dir: docklets_dir,
)
