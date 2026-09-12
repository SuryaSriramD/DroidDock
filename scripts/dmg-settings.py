"""Finder presentation for the DroidDock drag-to-install disk image.

The background and icon positions use the same 720 x 460 point canvas.
Settings reference: https://dmgbuild.readthedocs.io/en/latest/settings.html
"""

from pathlib import Path

project = Path(defines["project"])
support = Path(defines["support"])
application = project / "artifacts" / "DroidDock.app"

format = "UDZO"
filesystem = "HFS+"
files = [str(application), (str(support), ".support")]
symlinks = {"Applications": "/Applications"}
icon = str(project / "Resources" / "AppIcon.icns")
# dmgbuild uses Apple's tiffutil to combine the 1x and @2x PNGs for Finder.
background = str(project / "Resources" / "DMG" / "background.png")

# WindowBounds includes the 32-point Finder title bar on the validated macOS.
window_rect = ((240, 200), (720, 492))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
# Finder rejects icon-view settings when grid spacing is 100 or greater.
grid_spacing = 80
scroll_position = (0, 0)
icon_size = 112
text_size = 14
label_pos = "bottom"
show_icon_preview = False
show_item_info = False
icon_locations = {"DroidDock.app": (190, 246), "Applications": (530, 246)}
# Let Finder apply its normal app-name display. SetFile extension-hiding adds
# FinderInfo to the signed bundle and fails strict codesign verification.
