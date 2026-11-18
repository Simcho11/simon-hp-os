# Part of the hp-os-session launcher (hp-os.nix); uses its root, main, text and write.
# Logging in now fades through black, so niri's first frame stays black. Configs from the earlier
# build still include this file: keep it present and empty.
write(root/'config.d/63-login-backdrop.kdl', '')
# A new account's config.kdl is first written here, after Home Manager's activation has already run,
# so the house rules (free-floating windows, no blur over the Applications view) are included here too.
house_include = 'include "config.d/49-hp-snap.kdl"'
if (root/'config.d/49-hp-snap.kdl').exists() and house_include not in (line.strip() for line in text.splitlines()):
    text = text.rstrip() + '\n' + house_include + '\n'
    write(main, text)
# Fcitx's "Wayland Diagnose" pop-up is advice for people configuring input methods by hand. HP-OS sets
# these variables on purpose, so nobody should be greeted by it (the same as "Do not show again").
fcitx_notices = pathlib.Path(os.environ.get('XDG_CONFIG_HOME', str(pathlib.Path.home()/'.config')))/'fcitx5/conf/notifications.conf'
fcitx_hidden = [line.split('=', 1)[1].strip() for line in (fcitx_notices.read_text().splitlines() if fcitx_notices.exists() else []) if '=' in line]
fcitx_wanted = fcitx_hidden + [name for name in ('wayland-diagnose-other', 'wayland-diagnose-gnome', 'wayland-diagnose-kde') if name not in fcitx_hidden]
if fcitx_wanted != fcitx_hidden:
    fcitx_notices.parent.mkdir(parents=True, exist_ok=True)
    write(fcitx_notices, '[HiddenNotifications]\n' + ''.join(f'{index}={name}\n' for index, name in enumerate(fcitx_wanted)))
# Window snapping's keys, for accounts that have the snapping app (home.nix). HP-OS's binding sync keeps
# changes made to config.kdl's own binds, and refuses to run if an included file binds the same keys.
snap_command = pathlib.Path.home()/'.local/share/hp-os/bin/hp-snap'
if snap_command.exists():
    import re
    snap_keys = [('Mod+Left', 'Snap window left', '"key" "left"'), ('Mod+Right', 'Snap window right', '"key" "right"'),
                 ('Mod+Up', 'Snap window up / maximize', '"key" "up"'), ('Mod+Down', 'Snap window down / restore', '"key" "down"'),
                 ('Mod+Z', 'Snap layouts', '"picker"')]
    snap_block = re.search(r'(?ms)^binds[ \t]*\{\n(.*?)^\}', text)
    if snap_block:
        snap_body = snap_block.group(1)
        for snap_key, snap_title, snap_args in snap_keys:
            snap_line = f'    {snap_key} hotkey-overlay-title="{snap_title}" {{ spawn "{snap_command}" {snap_args}; }}\n'
            snap_body, snap_found = re.subn(r'(?im)^[ \t]*' + re.escape(snap_key) + r'(?=[ \t{])[^\n]*\}[ \t]*\n', lambda _: snap_line, snap_body, count=1)
            if not snap_found and not re.search(r'(?im)^[ \t]*' + re.escape(snap_key) + r'(?=[ \t{])', snap_body):
                snap_body += snap_line
        snap_text = text[:snap_block.start(1)] + snap_body + text[snap_block.end(1):]
        if snap_text != text:
            text = snap_text
            write(main, text)
