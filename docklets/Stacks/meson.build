docklet_stacks_sources = [
  'StacksDockItem.vala',
  'StacksDocklet.vala',
  'StacksPreferences.vala',
]

docklet_stacks_resources = gnome.compile_resources(
  'docky-stacks-resources',
  'stacks.gresource.xml',
  c_name: 'docky_stacks',
)

shared_module(
  'docklet-stacks',
  docklet_stacks_sources,
  docklet_stacks_resources,
  dependencies: [plank_dep, plank_base_dep],
  install: true,
  install_dir: docklets_dir,
)
