"""hp-snap's changes to HP-OS's session launcher (bin/.hp-os-wrapped), applied at build time.

Usage: launcher.py WRAPPED_FILE
Each change replaces one exact anchor line; the build fails if an anchor is missing, so an HP-OS
update that moves these lines is noticed instead of silently dropping hp-snap behaviour.
"""
import pathlib
import sys

SESSION_ANCHOR = '    exec python3 "$packaging/session-supervisor.py" dbus-run-session --config-file="$dbus_session_config" -- niri --config "$INIR_NIRI_CONFIG_DIR/config.kdl"\n'
SESSION_NEW = '''    # hp-snap: run niri on the normal session bus, not a private one. Chrome, Teams and the
    # screen-share portal all use the session bus, and niri's screen-cast service
    # (org.gnome.Mutter.ScreenCast) must be there for screen sharing to work.
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    # hp-snap: right after an automatic login, niri hides the cursor from its first frame until the
    # boot cover has faded into the lock screen (boot-cover/start.sh empties the file again). Rewritten
    # at every login, so a hidden cursor can never outlive the session that needed it. Only an account
    # that has the boot cover hides it (nothing else gives it back), and never for more than a minute.
    boot_cursor="$INIR_NIRI_CONFIG_DIR/config.d/48-boot-cursor.kdl"
    if [[ -f "$boot_cursor" ]]; then
      boot_cursor_shown='// hp-snap: written by the session launcher at every login. Empty, except right after an automatic\\n// login, when it hides the cursor until the boot cover has faded into the lock screen.\\n'
      if [[ -x "$HOME/.local/share/hp-snap/boot-cover/start.sh" ]] \\
          && [[ -n "${XDG_SESSION_ID:-}" && ! -e "${XDG_RUNTIME_DIR:-/tmp}/hp-snap-boot-cover-$XDG_SESSION_ID" ]] \\
          && [[ "$(loginctl show-session "$XDG_SESSION_ID" -p Service --value 2>/dev/null)" =~ ^(gdm|sddm)-autologin$ ]]; then
        printf '// hp-snap: boot cover running; boot-cover/start.sh empties this file again.\\ncursor {\\n    hide-after-inactive-ms 1\\n}\\n' > "$boot_cursor" || true
        ( sleep 60; ! grep -q hide-after-inactive-ms "$boot_cursor" || printf "$boot_cursor_shown" > "$boot_cursor" ) >/dev/null 2>&1 &
      else
        printf "$boot_cursor_shown" > "$boot_cursor" || true
      fi
    fi
    exec python3 "$packaging/session-supervisor.py" niri --config "$INIR_NIRI_CONFIG_DIR/config.kdl"
'''

RUN_ANCHOR = '      dbus-update-activation-environment "${activation_vars[@]}"\n'
RUN_NEW = RUN_ANCHOR + '''      # hp-snap: screen sharing. The user's portal services outlive a logout and keep the old
      # desktop's state, and the portal only sees screen sharing when the GNOME backend is
      # already running when it starts. Point them at this desktop, start the backend, then
      # the portal (in the background, so the shell is not delayed).
      ( dbus-update-activation-environment --systemd "${activation_vars[@]}"
        systemctl --user restart xdg-desktop-portal-gnome.service
        systemctl --user restart xdg-desktop-portal.service ) >/dev/null 2>&1 &
      # hp-snap: tell GDM the display is ready now (GNOME Shell does this itself). Otherwise GDM's
      # 10 s fallback quits the boot splash with a plain "plymouth quit", which switches to VT 1,
      # and GDM then starts its login screen there on top of an automatic login.
      gdbus call --system --dest org.gnome.DisplayManager --object-path /org/gnome/DisplayManager/Manager \\
        --method org.gnome.DisplayManager.Manager.RegisterDisplay >/dev/null 2>&1 &
      # hp-snap: after an automatic login, start on the HP-OS lock screen (once per session, so a
      # shell restart or a password login does not lock again).
      autolock_flag="${XDG_RUNTIME_DIR:-/tmp}/hp-snap-autolock-${XDG_SESSION_ID:-none}"
      if [[ ! -e "$autolock_flag" && -n "${XDG_SESSION_ID:-}" ]] \\
          && [[ "$(loginctl show-session "$XDG_SESSION_ID" -p Service --value 2>/dev/null)" =~ ^(gdm|sddm)-autologin$ ]]; then
        : > "$autolock_flag"
        # The shell reads (and removes) this once its settings are loaded, then locks.
        echo lock > "${XDG_RUNTIME_DIR:-/tmp}/hp-snap-autolock-request"
      fi
'''

def edit(path, changes):
    text = path.read_text()
    for anchor, new in changes:
        if text.count(anchor) != 1:
            sys.exit(f"hp-snap launcher.py: {path.name}: expected exactly one anchor, found {text.count(anchor)}:\n{anchor}")
        text = text.replace(anchor, new)
    path.write_text(text)


edit(pathlib.Path(sys.argv[1]), ((SESSION_ANCHOR, SESSION_NEW), (RUN_ANCHOR, RUN_NEW)))

# Optional: launcher.py WRAPPED HP_OS_BIN XWAYLAND_SATELLITE puts the patched xwayland-satellite
# first on PATH (niri starts whichever xwayland-satellite comes first).
if len(sys.argv) == 4:
    wrapper = pathlib.Path(sys.argv[2])
    exec_line = next(line for line in wrapper.read_text().splitlines(keepends=True)
                     if line.startswith('exec -a "$0" '))
    edit(wrapper, ((exec_line,
        "# hp-snap: patched xwayland-satellite (maximize/minimize for X11 apps such as Steam) ahead of\n"
        "# HP-OS's own; niri starts whichever xwayland-satellite comes first on its PATH.\n"
        f"PATH='{sys.argv[3]}/bin':$PATH\n" + exec_line),))
