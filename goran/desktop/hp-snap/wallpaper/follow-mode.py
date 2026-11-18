"""Show the light wallpaper in light mode and the dark one in dark mode.

Usage: follow-mode.py LIGHT_WALLPAPER DARK_WALLPAPER
Reads the shell's mode (~/.local/state/hp-os/appearance-mode, written whenever light/dark changes;
light when missing) and sets background.wallpaperPath in ~/.config/hp-os/config.json to match.
A wallpaper the user picked themselves is left alone: only the pair, HP-OS's stock wallpaper or
no wallpaper at all is replaced. Run by hp-os-app-theme.service and at activation.
"""
import json
import os
import pathlib
import sys
import tempfile
import time

light, dark = sys.argv[1], sys.argv[2]
home = pathlib.Path.home()
state = pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "hp-os/appearance-mode"
config_path = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")) / "hp-os/config.json"

try:
    mode = state.read_text().strip()
except OSError:
    mode = "light"
target = dark if mode == "dark" else light


def ours(path):
    return (not path or path in (light, dark, "__HPOS_WALLPAPER__")
            or path.endswith("/assets/hpos-wallpaper.png"))


def read():
    try:
        return json.loads(config_path.read_text())
    except (OSError, ValueError):
        return None


# The running shell rewrites config.json on its own saves: check the change stuck, as daylight.py does.
for attempt in range(3):
    config = read()
    if config is None:
        sys.exit(0)  # no config yet; HP-OS creates it at first login and this runs again
    current = config.get("background", {}).get("wallpaperPath", "")
    if current == target or not ours(current):
        sys.exit(0)
    config.setdefault("background", {})["wallpaperPath"] = target
    config["background"]["thumbnailPath"] = ""
    fd, temporary = tempfile.mkstemp(prefix="." + config_path.name, dir=config_path.parent)
    with os.fdopen(fd, "w") as stream:
        json.dump(config, stream, indent=4)
        stream.write("\n")
    os.chmod(temporary, config_path.stat().st_mode & 0o777)
    os.replace(temporary, config_path)
    time.sleep(1.5)
