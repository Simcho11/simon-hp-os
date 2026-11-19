#!/bin/bash
# Install the HP-OS "Add user" setup behind the login screen's Add user button.
#
#   sudo goran/installer/system/hp-os-add-user.sh          install / update
#   sudo goran/installer/system/hp-os-add-user.sh --undo   take it out again
#
# Puts the app in the Nix store, registers the button's hpos-add-user: link, and lets the app ask for
# the administrator's approval itself (the login screen's generic pop-up agent is removed).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
admin="${SUDO_USER:-}"
[[ -n "$admin" && "$admin" != root ]] || { echo "Run with sudo from your own account." >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
launcher=/usr/share/applications/hpos-add-user.desktop
profile=/nix/var/nix/profiles/hp-os-add-user
greeter=/opt/hp-os/login/greeter.kdl
greeter_backup=$greeter.bak-before-add-user
niri=/opt/hp-os/niri-patch/result-hpos/bin/niri

if [[ "${1:-}" == --undo ]]; then
    "$here/hp-os-settings-access.sh" --undo
    "$here/hp-os-device-setup.sh" --undo
    rm -f "$launcher"
    update-desktop-database -q /usr/share/applications || true
    "$here/hp-os-login-theme.sh" --undo-last
    [[ ! -f "$greeter_backup" ]] || cp -a "$greeter_backup" "$greeter"
    echo "Add user removed; the previous login screen is back."
    exit 0
fi

echo "Building Add user (as $admin)..."
built=$(sudo -u "$admin" -H /usr/bin/nix build --no-link --print-out-paths \
        --extra-experimental-features 'nix-command flakes' "path:$repo#hp-os-add-user")
/usr/bin/nix-env --profile "$profile" --set "$built"

# Checked before anything on the login screen changes.
if grep -q 'polkit-gnome-authentication-agent-1' "$greeter"; then
    candidate=$(mktemp)
    grep -v -e 'polkit-gnome-authentication-agent-1"$' -e "greeter's own authorization agent" "$greeter" > "$candidate"
    "$niri" validate --config "$candidate" || { echo "$greeter edit is not valid; nothing changed." >&2; exit 1; }
    [[ -f "$greeter_backup" ]] || cp -a "$greeter" "$greeter_backup"
    install -m 644 -o root -g root "$candidate" "$greeter"
    rm -f "$candidate"
fi

cat > "$launcher" <<EOF
[Desktop Entry]
Type=Application
Name=Add user
Exec=$profile/bin/hp-os-add-user %u
MimeType=x-scheme-handler/hpos-add-user;
NoDisplay=true
Terminal=false
EOF
chmod 644 "$launcher"
update-desktop-database -q /usr/share/applications

# Brightness, touchpad feedback and AirDrop for every account. Before the accounts are updated below,
# because their setup links the AirDrop published here.
"$here/hp-os-settings-access.sh"
# First-time setup on a new device, and factory reset in Settings.
"$here/hp-os-device-setup.sh"
"$here/hp-os-login-theme.sh"
# Publishes first-time setup with its progress, and the sign-in step that shows it.
"$here/hp-os-login-session.sh"
echo "Add user is installed. It appears the next time the login screen starts."
