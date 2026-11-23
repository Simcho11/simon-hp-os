#!/bin/bash
# Install the HP-OS login screen (goran/desktop/hp-snap/login-theme, built as .#hp-os-login-theme)
# over /opt/hp-os/login/themes/hpos. The theme's existing fonts stay; the first run keeps a copy of
# the previous theme.
#
#   sudo goran/installer/system/hp-os-login-theme.sh          install / update
#   sudo goran/installer/system/hp-os-login-theme.sh --undo-last   put back the theme from before the last install
#   sudo goran/installer/system/hp-os-login-theme.sh --undo   put the original theme back
# Shows at the next login screen (log out, Switch user, or reboot).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
admin="${SUDO_USER:-}"
[[ -n "$admin" && "$admin" != root ]] || { echo "Run with sudo from your own account." >&2; exit 1; }

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
theme=/opt/hp-os/login/themes/hpos
backup=/opt/hp-os/login/themes/hpos.bak-before-hp-os-theme
previous=/opt/hp-os/login/themes/hpos.bak-previous
greeter=/opt/hp-os/login/greeter.kdl
greeter_backup=$greeter.bak-before-black-background
niri=/opt/hp-os/niri-patch/result-hpos/bin/niri

restore_greeter() {
    [[ ! -f "$greeter_backup" ]] || cp -a "$greeter_backup" "$greeter"
}
if [[ "${1:-}" == --undo-last ]]; then
    [[ -d "$previous" ]] || { echo "No backup at $previous." >&2; exit 1; }
    rm -rf "$theme"
    cp -a "$previous" "$theme"
    restore_greeter
    echo "Restored the login screen from before the last install ($previous)."
    exit 0
fi
if [[ "${1:-}" == --undo ]]; then
    [[ -d "$backup" ]] || { echo "No backup at $backup." >&2; exit 1; }
    rm -rf "$theme"
    cp -a "$backup" "$theme"
    restore_greeter
    echo "Restored the previous login screen from $backup."
    exit 0
fi

[[ -d "$theme" ]] || { echo "Missing $theme." >&2; exit 1; }
[[ -d "$backup" ]] || cp -a "$theme" "$backup"

echo "Building the login screen (as $admin)..."
built=$(sudo -u "$admin" -H /usr/bin/nix build --no-link --print-out-paths \
        --extra-experimental-features 'nix-command flakes' "path:$repo#hp-os-login-theme")

# Black behind the login screen as it closes, instead of niri's grey. Checked before it is installed.
if ! grep -q 'background-color' "$greeter"; then
    candidate=$(mktemp)
    sed '0,/^layout {/s//layout {\n    background-color "#000000"/' "$greeter" > "$candidate"
    grep -q 'background-color "#000000"' "$candidate" || { echo "Could not edit $greeter; nothing changed." >&2; exit 1; }
    "$niri" validate --config "$candidate" || { echo "$greeter edit is not valid; nothing changed." >&2; exit 1; }
    [[ -f "$greeter_backup" ]] || cp -a "$greeter" "$greeter_backup"
    install -m 644 -o root -g root "$candidate" "$greeter"
    rm -f "$candidate"
fi

# The theme as it is now, for --undo-last.
rm -rf "$previous"
cp -a "$theme" "$previous"

# The new theme is put together beside the old one (files only; Inter, Rubik and Material Symbols in fonts/ stay),
# then swapped in with a single rename: a power cut can never leave a half-copied login screen nobody can sign in past.
staging="$theme.new"
rm -rf "$staging"
cp -a "$theme" "$staging"
cp -r --no-preserve=mode,ownership "$built"/. "$staging"/
chown -R root:root "$staging"
chmod -R u=rwX,go=rX "$staging"
sync -f "$staging" 2>/dev/null || sync
if /usr/bin/mv --exchange -T "$staging" "$theme" 2>/dev/null; then
    rm -rf "$staging"           # The old theme, after the swap.
else
    # A system whose mv can't swap: copied over in place, as before.
    rm -rf "$staging"
    cp -r --no-preserve=mode,ownership "$built"/. "$theme"/
    chown -R root:root "$theme"
    chmod -R u=rwX,go=rX "$theme"
fi
echo "Installed the HP-OS login screen from $built (previous theme: $backup)."
