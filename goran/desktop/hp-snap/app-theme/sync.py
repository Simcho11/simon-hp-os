#!/usr/bin/python3
"""Keep GTK and Qt applications in step with the HP-OS shell.

The shell owns three choices: light/dark (~/.local/state/hp-os/appearance-mode),
the accent colour (iris.appearance.accentHex in ~/.config/hp-os/config.json) and
the font (HarmonyOS Sans). This publishes them to GTK3 and GTK4/libadwaita
applications, and the font to KDE/Qt ones. HP-OS Files and COSMIC apps keep the
palette their packages ship (HarmonyOS blue). It is idempotent and only writes what changed.

Run by hp-os-app-theme.path / hp-os-app-theme.service; safe to run by hand.
To remove: systemctl --user disable --now hp-os-app-theme.path hp-os-app-theme.service
and restore the files in backup-2026-11-10/ next to this script.
"""
import colorsys
import configparser
import json
import os
from io import StringIO
from pathlib import Path
import subprocess
import tempfile

HOME = Path.home()
CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', HOME / '.config'))
STATE = Path(os.environ.get('XDG_STATE_HOME', HOME / '.local/state'))

FONT = 'HarmonyOS Sans'
MONO = 'Fira Mono'
SIZE = 11
FALLBACK_ACCENT = '#0a59f7'  # HarmonyOS brand blue
WINDOW_RADIUS = 16           # matches niri geometry-corner-radius
ICONS = 'HP-OS'
GSETTINGS = '/usr/bin/gsettings'  # the system build; it can reach both stores
# GNOME's named accents, for the few places that only take a name.
GNOME_ACCENTS = {'blue': 213, 'teal': 187, 'green': 129, 'yellow': 43, 'orange': 26,
                 'red': 356, 'pink': 329, 'purple': 286}


def write_if_changed(path, text):
    if path.exists() and path.read_text() == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        stream.write(text)
    os.chmod(stream.name, mode)
    os.replace(stream.name, path)
    return True


def shell_mode():
    try:
        mode = (STATE / 'hp-os/appearance-mode').read_text().strip()
    except OSError:
        mode = ''
    return mode if mode in ('light', 'dark') else 'dark'


def shell_accent():
    try:
        appearance = json.loads((CONFIG / 'hp-os/config.json').read_text())['iris']['appearance']
        accent = appearance['accentHex'] if appearance.get('accent') == 'hex' else ''
    except (OSError, ValueError, KeyError, TypeError):
        accent = ''
    accent = accent.strip().lower()
    if len(accent) == 7 and accent[0] == '#' and all(c in '0123456789abcdef' for c in accent[1:]):
        return accent
    return FALLBACK_ACCENT


def rgb(colour):
    return tuple(int(colour[i:i + 2], 16) for i in (1, 3, 5))


def to_hex(values):
    return '#' + ''.join(f'{round(max(0, min(255, v))):02x}' for v in values)


def mix(colour, other, amount):
    return to_hex(a + (b - a) * amount for a, b in zip(rgb(colour), rgb(other)))


def luminance(colour):
    channels = [c / 255 for c in rgb(colour)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def readable(colour, background, towards):
    """Shift colour towards black/white until it reads as text on background."""
    for step in range(0, 20):
        candidate = mix(colour, towards, step * 0.05)
        if contrast(candidate, background) >= 4.5:
            return candidate
    return towards


def palette(accent, mode):
    dark = mode == 'dark'
    on_accent = '#ffffff' if contrast('#ffffff', accent) >= 3 else mix('#000000', accent, 0.12)
    text = readable(accent, '#242424', '#ffffff') if dark else readable(accent, '#fafafa', '#000000')
    return {'bg': accent, 'fg': on_accent, 'text': text}


def gtk_css(accent, mode, gtk4):
    colours = palette(accent, mode)
    lines = [
        '/* Written by ~/.local/share/hp-os-app-theme/sync.py - edits here are overwritten. */',
        f'@define-color accent_bg_color {colours["bg"]};',
        f'@define-color accent_fg_color {colours["fg"]};',
    ]
    if gtk4:
        # libadwaita derives the text accent for each of light and dark itself.
        lines += [
            ':root {',
            f'  --accent-bg-color: {colours["bg"]};',
            f'  --accent-fg-color: {colours["fg"]};',
            f'  --window-radius: {WINDOW_RADIUS}px;',
            '}',
        ]
    else:
        lines.append(f'@define-color accent_color {colours["text"]};')
    if RED_CLOSE_HOVER and not (CONFIG / 'hp-os/plain-close-button').exists():
        lines += red_close_hover_css(gtk4)
    return '\n'.join(lines) + '\n'


# The window close button turns red while hovered, as on Windows.
# To turn it off for everyone: set RED_CLOSE_HOVER = False and rebuild.
# To turn it off for one user right away: touch ~/.config/hp-os/plain-close-button
# and run this script (or toggle light/dark).
RED_CLOSE_HOVER = True
CLOSE_RED = '#e01b24'


def red_close_hover_css(gtk4):
    if gtk4:
        # libadwaita draws the round bubble on the button's icon, not the button itself.
        return [
            'windowcontrols > button.close:hover > image,',
            'windowcontrols > button.close:active > image {',
            f'  background-color: {CLOSE_RED};',
            '  color: #ffffff;',
            '}',
        ]
    return [
        'headerbar button.titlebutton.close:hover,',
        '.titlebar button.titlebutton.close:hover,',
        'headerbar button.titlebutton.close:active,',
        '.titlebar button.titlebutton.close:active {',
        f'  background-color: {CLOSE_RED};',
        '  background-image: none;',
        '  color: #ffffff;',
        '}',
    ]


def sync_settings_ini(path, theme, dark):
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    if path.exists():
        parser.read(path)
    if 'Settings' not in parser:
        parser['Settings'] = {}
    settings = parser['Settings']
    settings['gtk-theme-name'] = theme
    settings['gtk-font-name'] = f'{FONT} {SIZE}'
    settings['gtk-icon-theme-name'] = ICONS
    if path.parent.name == 'gtk-4.0':
        # libadwaita follows color-scheme and warns about the GTK3-era flag.
        settings.pop('gtk-application-prefer-dark-theme', None)
    else:
        settings['gtk-application-prefer-dark-theme'] = '1' if dark else '0'
    output = StringIO()
    parser.write(output, space_around_delimiters=False)
    write_if_changed(path, output.getvalue())


def sync_gsettings(values):
    """Publish to both settings stores.

    System applications and portals read dconf. Applications from the Nix
    profile have no dconf module and read GLib's keyfile instead, so the two
    drift apart unless both are written.
    """
    for backend in ('dconf', 'keyfile'):
        env = dict(os.environ, GSETTINGS_BACKEND=backend)
        for key, value in values.items():
            current = subprocess.run([GSETTINGS, 'get', 'org.gnome.desktop.interface', key],
                                     capture_output=True, text=True, env=env, timeout=10)
            if current.stdout.strip().strip("'") != value:
                subprocess.run([GSETTINGS, 'set', 'org.gnome.desktop.interface', key, value],
                               env=env, check=False, timeout=10)


def set_kconfig(path, group, values):
    """Set keys in one KConfig group, leaving every other line untouched."""
    lines = path.read_text().splitlines() if path.exists() else []
    header = f'[{group}]'
    start = next((i for i, line in enumerate(lines) if line.strip() == header), None)
    if start is None:
        if lines and lines[-1].strip():
            lines.append('')
        lines.append(header)
        start = len(lines) - 1
    end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('[')),
               len(lines))
    body = [line for line in lines[start + 1:end]
            if line.strip() and line.partition('=')[0].strip() not in values]
    body += [f'{key}={value}' for key, value in values.items() if value is not None]
    if end < len(lines):
        body.append('')
    write_if_changed(path, '\n'.join(lines[:start + 1] + body + lines[end:]) + '\n')


def nearest_gnome_accent(accent):
    red, green, blue = (c / 255 for c in rgb(accent))
    hue, _, saturation = colorsys.rgb_to_hls(red, green, blue)
    if saturation < 0.12:
        return 'slate'
    hue *= 360
    return min(GNOME_ACCENTS, key=lambda name: min(abs(hue - GNOME_ACCENTS[name]),
                                                   360 - abs(hue - GNOME_ACCENTS[name])))


def main():
    mode = shell_mode()
    dark = mode == 'dark'
    accent = shell_accent()
    theme = 'adw-gtk3-dark' if dark else 'adw-gtk3'

    write_if_changed(CONFIG / 'gtk-3.0/dank-colors.css', gtk_css(accent, mode, gtk4=False))
    write_if_changed(CONFIG / 'gtk-4.0/dank-colors.css', gtk_css(accent, mode, gtk4=True))
    for version in ('gtk-3.0', 'gtk-4.0'):
        sync_settings_ini(CONFIG / version / 'settings.ini', theme, dark)
    sync_gsettings({
        'gtk-theme': theme,
        'color-scheme': 'prefer-' + mode,
        'icon-theme': ICONS,
        'font-name': f'{FONT} {SIZE}',
        'document-font-name': f'{FONT} {SIZE + 1}',
        'monospace-font-name': f'{MONO} {SIZE}',
        'accent-color': nearest_gnome_accent(accent),
    })

    kde_font = f'{FONT},{SIZE},-1,5,50,0,0,0,0,0'
    set_kconfig(CONFIG / 'kdeglobals', 'General', {
        'font': kde_font, 'menuFont': kde_font, 'toolBarFont': kde_font,
        'smallestReadableFont': f'{FONT},{SIZE - 2},-1,5,50,0,0,0,0,0',
        'fixed': f'{MONO},{SIZE},-1,5,50,0,0,0,0,0',
    })


if __name__ == '__main__':
    main()
