"""Give windows their minimize, maximize and close buttons in GLib's keyfile settings.

Usage: buttons.py LAYOUT
HP-OS's Nix-built GTK/libadwaita apps read ~/.config/glib-2.0/settings/keyfile instead of dconf,
so a layout set only in dconf never reaches them (they then show a title bar without buttons).
Only the one key is touched.
"""
import configparser
import os
import pathlib
import sys
import tempfile

layout = sys.argv[1]
home = pathlib.Path.home()
path = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")) / "glib-2.0/settings/keyfile"
section, key, value = "org/gnome/desktop/wm/preferences", "button-layout", f"'{layout}'"

parser = configparser.ConfigParser(interpolation=None)
parser.optionxform = str
if path.exists():
    parser.read(path)
if parser.has_option(section, key) and parser.get(section, key) == value:
    sys.exit(0)
if not parser.has_section(section):
    parser.add_section(section)
parser.set(section, key, value)
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".keyfile", dir=path.parent)
with os.fdopen(fd, "w") as stream:
    parser.write(stream, space_around_delimiters=False)
os.replace(temporary, path)
