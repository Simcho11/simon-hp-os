#!/bin/bash
# System part of HP-OS multi-user (outside Home Manager): make SDDM start each account's OWN
# HP-OS. Before this, every account other than simon was sent to /opt/hp-os/session, which is
# built for /home/simon and left other people on a gray screen.
#
#   sudo goran/installer/system/hp-os-login-session.sh          install
#   sudo goran/installer/system/hp-os-login-session.sh --undo   put the previous version back
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

target=/opt/hp-os/login/session
backup="$target.bak-before-per-user-hp-os"

if [[ "${1:-}" == --undo ]]; then
    [[ -f "$backup" ]] || { echo "No backup at $backup." >&2; exit 1; }
    cp -a "$backup" "$target"
    rm -f /etc/shadow-maint/useradd-post.d/hp-os-nix-group
    echo "Restored $target from $backup."
    exit 0
fi

[[ -f "$target" ]] || { echo "Missing $target (run hpos-multiuser-install.sh first)." >&2; exit 1; }
[[ -f "$backup" ]] || cp -a "$target" "$backup"

# Publish the first-login setup in the Nix store so private checkouts can stay private.
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
[[ -n ${SUDO_USER:-} && "$SUDO_USER" != root ]] || { echo 'Run with sudo from the checkout owner account.' >&2; exit 1; }
setup=$(sudo -u "$SUDO_USER" -H /usr/bin/nix --extra-experimental-features 'nix-command flakes' build \
    --print-out-paths --no-link "$repo#hp-os-account-setup")
/usr/bin/nix-env --profile /nix/var/nix/profiles/hp-os-accounts --set "$setup"
install -Dm755 "$repo/goran/installer/system/hp-os-nix-group" /etc/shadow-maint/useradd-post.d/hp-os-nix-group

# The earlier always-running safeguard is no longer needed.
if [[ -e /etc/systemd/system/hp-os-login-guard.service ]]; then
    systemctl disable --now hp-os-login-guard.service 2>/dev/null || true
    rm -f /etc/systemd/system/hp-os-login-guard.service /opt/hp-os/login/login-guard
    systemctl daemon-reload
fi

cat > "$target.new" <<'EOF'
#!/bin/bash
# HP-OS session started by SDDM (see /etc/sddm.conf.d/90-hpos.conf).
#
# Always end with exit status 0. sddm-helper passes the session's status on, and SDDM reads 1 as
# HELPER_AUTH_ERROR: it then waits for the (already closed) login screen instead of starting a new
# one, leaving a blank, unrecoverable screen. A logout, a crash or a failed first-login setup must
# all return to the login screen; the real status goes to the journal (journalctl -t hp-os-session).
#
# Signing out always ends on the login screen. SDDM opens one by itself only when nobody else is signed
# in; otherwise it jumps to the newest display it knows, which is another account's lock screen or an
# empty, black terminal. So with someone else signed in, open the login screen before this session ends:
# it is then the newest display, and SDDM stays on it.
login_screen_first() {
    local others active
    [[ "$(/usr/bin/systemctl is-system-running 2>/dev/null)" != stopping ]] || return 0
    others=$(/usr/bin/loginctl list-sessions --no-legend 2>/dev/null \
        | /usr/bin/awk -v own="${XDG_SESSION_ID:-}" '$1 != own && $4 == "seat0" && $6 ~ /^user/')
    [[ -n "$others" ]] || return 0
    /usr/bin/timeout 5 /usr/bin/gdbus call --system --dest org.freedesktop.DisplayManager \
        --object-path /org/freedesktop/DisplayManager/Seat0 \
        --method org.freedesktop.DisplayManager.Seat.SwitchToGreeter >/dev/null 2>&1 || return 0
    for _ in {1..32}; do
        active=$(/usr/bin/loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
        if [[ -n "$active" && "$(/usr/bin/loginctl show-session "$active" -p Class --value 2>/dev/null)" == greeter ]]; then
            return 0
        fi
        /usr/bin/sleep 0.25
    done
}
finish() {
    local status=$1 what=$2
    logger -t hp-os-session "$what for ${USER:-?} ended with status $status" 2>/dev/null || true
    login_screen_first
    exit 0
}

# First login of a new account: create its HP-OS settings from shared defaults (private home).
/usr/bin/python3 /opt/hp-os/login/initialize-profile.py || finish $? "profile setup"
set -uo pipefail
# A password login has just been checked by the HP-OS login screen, so skip the startup lock.
# An automatic login keeps it, so the machine would still start on the HP-OS lock screen.
service="$(loginctl show-session "${XDG_SESSION_ID:-}" -p Service --value 2>/dev/null || true)"
unset HP_OS_AUTHENTICATED_LOGIN
if [[ "$service" == sddm || "$service" == gdm-password ]]; then
    export HP_OS_AUTHENTICATED_LOGIN=1
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] && rm -f -- "$XDG_RUNTIME_DIR/hp-snap-autolock-request"
fi

setup=/nix/var/nix/profiles/hp-os-accounts/bin/hp-os-account-setup
# Still to be set up (for example an account made with adduser): HP logo and a progress bar.
first_setup=/nix/var/nix/profiles/hp-os-add-user/bin/hp-os-first-setup
if [[ -x "$first_setup" ]] && "$setup" --needed; then
    "$first_setup" || logger -t hp-os-session "first-setup screen for ${USER:-?} ended with status $?" 2>/dev/null || true
fi
"$setup" || finish $? "first-login setup"
own="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager/home-path/bin"
export PATH="$own:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin"
[[ -x "$own/hp-os-session" ]] || finish 127 "missing $own/hp-os-session"
# This account's wallpaper on the login screen: shared as the session starts (in the background) and again as it
# ends, when it changed during the session.
wallpaper=/opt/hp-os/device/hp-os-login-wallpaper
[[ ! -x "$wallpaper" ]] || ( timeout 120 /usr/bin/python3 -I "$wallpaper" share >/dev/null 2>&1 & )
# Not exec: this script must outlive the session to hand SDDM a clean status.
"$own/hp-os-session"
status=$?
[[ ! -x "$wallpaper" ]] || timeout 20 /usr/bin/python3 -I "$wallpaper" share >/dev/null 2>&1 || true
finish $status "HP-OS session"
EOF
bash -n "$target.new"
chmod 755 "$target.new"
mv "$target.new" "$target"
echo "Installed $target (previous version: $backup)."

# Accounts created later run the same setup at their first HP-OS login.
failed=0
while IFS=: read -r name _ uid _ _ directory shell; do
    [[ $uid -ge 1000 && $uid -le 60000 && "$directory" == "/home/$name" && "$shell" != */nologin && "$shell" != */false ]] || continue
    "$repo/goran/installer/hp-os-user-apply.sh" "$name" || failed=1
done < <(getent -s files passwd)
exit "$failed"
