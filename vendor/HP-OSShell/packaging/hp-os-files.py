#!@python@
"""Launch Files with an HP-OS-only profile, retaining the user's real data."""
import json
import os
from pathlib import Path
import sys
import tempfile

from hp_os_theme import apply_files_palette


def upgrade_seeded_fonts(path):
    """Update only our original font and icon theme defaults; retain user fonts and other keys."""
    original = path.read_text()
    lines = original.splitlines(keepends=True)
    group = ""
    for index, line in enumerate(lines):
        value = line.rstrip("\r\n")
        if value.startswith("["):
            group = value
        if group == "[General]" and value in (
            key + "=Inter,11,-1,5,50,0,0,0,0,0"
            for key in ("font", "menuFont", "toolBarFont")
        ):
            lines[index] = line.replace("Inter,11,", "HarmonyOS Sans,12,", 1)
    updated = "".join(lines).replace("Theme=HarmonyOS\n", "Theme=HP-OS\n")
    # HP-OS-Files: HP-OS's icons, with the toolbar and menu icons drawn in the palette's colours.
    updated = updated.replace("[Icons]\nTheme=HP-OS\n", "[Icons]\nTheme=HP-OS-Files\n")
    if updated == original:
        return
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        output.write(updated)
    try:
        temporary.chmod(path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


# Launch-only values Qt consumes at startup; applications get fresh ones.
NOT_INHERITED = ("DESKTOP_STARTUP_ID", "XDG_ACTIVATION_TOKEN", "HP_OS_FILES_PARENT_ENV")


def parent_environment(environ):
    """The environment applications opened from Files start with.

    Files changes its own settings folder, Qt plugins and theme below. HP-OS
    Files' KIO starts applications from this saved copy instead, so they keep
    the user's own settings. A Files started from Files keeps the first copy.
    """
    saved = environ.get("HP_OS_FILES_PARENT_ENV")
    if saved:
        try:
            parent = json.loads(saved)
        except ValueError:
            parent = None
        if isinstance(parent, dict) and all(isinstance(v, str) for v in parent.values()):
            return parent
    return {key: value for key, value in environ.items() if key not in NOT_INHERITED}


def prepare_environment(environ, assets):
    env = dict(environ)
    env["HP_OS_FILES_PARENT_ENV"] = json.dumps(parent_environment(environ), separators=(",", ":"))
    home = Path(env["HOME"])
    original_config = Path(env.get("XDG_CONFIG_HOME", str(home / ".config")))
    shell_config = Path(env.get("INIR_CONFIG_DIR", str(original_config / "hp-os")))
    profile = shell_config / "apps" / "files"
    profile.mkdir(parents=True, exist_ok=True)
    for name in ("dolphinrc", "kdeglobals"):
        destination = profile / name
        # Seed once. Later user changes in the Files preferences remain intact.
        try:
            with destination.open("x") as output:
                output.write((assets / name).read_text())
        except FileExistsError:
            pass
    upgrade_seeded_fonts(profile / "kdeglobals")
    state = Path(env.get("XDG_STATE_HOME", str(home / ".local/state")))
    try:
        mode = (state / "hp-os/appearance-mode").read_text().strip()
    except FileNotFoundError:
        mode = "light"
    apply_files_palette(profile / "kdeglobals", assets, mode)

    # "Open with ... always" saves in Files' settings folder. Link it to HP-OS's
    # shared list of the user's own choices, so every app follows them (an older
    # private list is merged into the shared one when the desktop is updated).
    shared = original_config / "hp-os-mimeapps.list"
    choices = profile / "mimeapps.list"
    if not choices.exists() and not choices.is_symlink():
        if not shared.exists():
            original_config.mkdir(parents=True, exist_ok=True)
            with shared.open("a") as output:
                output.write("[Default Applications]\n")
        choices.symlink_to(shared)

    # Qt reads user-dirs.dirs directly from CONFIG_HOME, outside KConfig fallback.
    user_dirs = original_config / "user-dirs.dirs"
    destination = profile / "user-dirs.dirs"
    if user_dirs.exists() and not destination.exists() and not destination.is_symlink():
        destination.symlink_to(user_dirs)
    fallbacks = [str(original_config)] + env.get("XDG_CONFIG_DIRS", "/etc/xdg").split(":")
    env["XDG_CONFIG_HOME"] = str(profile)
    env["XDG_CONFIG_DIRS"] = ":".join(dict.fromkeys(x for x in fallbacks if x and x != str(profile)))
    env["XDG_DATA_DIRS"] = str(assets / "data") + ":" + env.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
    # Outside Plasma, Qt's default platform theme ignores KDE's saved palette.
    # Use the integration and style built with this Dolphin, independently of
    # the launching shell's Qt version and plugin paths.
    for name in ("QML_IMPORT_PATH", "QML2_IMPORT_PATH", "NIXPKGS_QT6_QML_IMPORT_PATH",
                 "NIXPKGS_QT6_PLUGIN_PATH"):
        env.pop(name, None)
    env["QT_PLUGIN_PATH"] = "@qtPlugins@"
    env["QT_QPA_PLATFORMTHEME"] = "kde"
    env["QT_STYLE_OVERRIDE"] = "Breeze"
    # XDG_DATA_HOME, HOME, bus and runtime directory deliberately stay unchanged:
    # Trash, bookmarks, MIME defaults and the active session keep their identity.
    return env


def main():
    assets = Path("@filesAssets@")
    env = prepare_environment(os.environ, assets)
    arguments = sys.argv[1:]
    # New Files windows (Open in New Window, Show in folder, a detached tab) start
    # through this launcher, so they get the same profile and theme.
    env["HP_OS_FILES_LAUNCHER"] = str(Path(__file__).resolve())
    # --daemon serves "Show in folder" (org.freedesktop.FileManager1) without a window.
    window = [] if "--daemon" in arguments else ["--new-window"]
    os.execve("@dolphin@", ["@dolphin@", *window, "-stylesheet", str(assets / "hpos-files.qss"), *arguments], env)


if __name__ == "__main__":
    main()
