"""Finder presentation for the MORIQ distribution image."""
from pathlib import Path

app = defines['app']
assets = Path(defines['assets'])
files = [app]
symlinks = {'Applications': '/Applications'}
icon = str(assets / 'moriq-volume.icns')
background = str(assets / 'dmg-background.png')
window_rect = ((120, 120), (720, 450))
default_view = 'icon-view'
icon_size = 96
text_size = 13
icon_locations = {'MORIQ.app': (235, 225), 'Applications': (485, 225)}
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
format = 'UDZO'
# dmgbuild's automatic estimate can undercount HFS metadata for large apps.
size = '5G'
