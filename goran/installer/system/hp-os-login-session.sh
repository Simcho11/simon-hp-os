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
own="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager/home-path/bin"
# hp-os-account-setup leaves how its last try went here: "running", "ok" or "failed REASON".
outcome_file="${XDG_STATE_HOME:-$HOME/.local/state}/hp-os/enrollment/outcome"
# When this account's desktop couldn't be set up, the login screen says why, in plain words: hp-os-device (root)
# keeps a note for it in /var/lib/hp-os/setup-notes, holding only the reason (storage, network or other).
setup_note() {
    printf '{"action": "setup-note", "reason": "%s"}\n' "$1" | /usr/bin/timeout 10 /usr/bin/python3 -I -c '
import socket, sys
connection = socket.socket(socket.AF_UNIX)
connection.settimeout(8)
connection.connect("/run/hp-os/factory-reset.sock")
connection.sendall(sys.stdin.readline().encode())
connection.makefile().readline()' >/dev/null 2>&1 || true
}
rm -f -- "$outcome_file" 2>/dev/null
# Still to be set up (for example an account made with adduser): HP logo and a progress bar, which runs the setup.
first_setup=/nix/var/nix/profiles/hp-os-add-user/bin/hp-os-first-setup
screen=0 outcome=""
if [[ -x "$first_setup" ]] && "$setup" --needed; then
    screen=1
    "$first_setup" || logger -t hp-os-session "first-setup screen for ${USER:-?} ended with status $?" 2>/dev/null || true
fi
# Never a second try after the screen's: a setup that failed there fails here too, on a black screen. Only when the
# screen never got to start it (no screen, or the screen itself couldn't open) does it run here.
if (( ! screen )) || [[ ! -s "$outcome_file" ]]; then
    "$setup" && outcome=ok
fi
[[ -n "${outcome:-}" ]] || outcome=$(head -c 64 -- "$outcome_file" 2>/dev/null)
if [[ "$outcome" != ok ]]; then
    case "$outcome" in
        "failed storage") reason=storage ;;
        "failed network") reason=network ;;
        "") # Nothing recorded: often a full disk, where nothing can be written.
            free=$(/usr/bin/df -Pk /nix/store "$HOME" 2>/dev/null | /usr/bin/awk 'NR > 1 && (least == "" || $4 < least) { least = $4 } END { print least + 0 }')
            if (( ${free:-0} > 0 && free < 1048576 )); then reason=storage; else reason=other; fi ;;
        *) reason=other ;;
    esac
    logger -t hp-os-session "first-login setup for ${USER:-?} didn't finish (${outcome:-nothing recorded}; $reason)" 2>/dev/null || true
    # No desktop yet: back to the login screen, which says what happened. It is set up again at the next sign-in.
    [[ -x "$own/hp-os-session" ]] || { setup_note "$reason"; finish 1 "first-login setup"; }
    # This account already has a desktop that works (the setup was for an update): open that one. The update is
    # tried again at the next sign-in.
fi
export PATH="$own:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin"
[[ -x "$own/hp-os-session" ]] || finish 127 "missing $own/hp-os-session"
# The desktop opens: the login screen's note about an earlier failed setup goes.
[[ ! -e "/var/lib/hp-os/setup-notes/${USER:-}.qml" ]] || setup_note ""
# This account's wallpaper on the login screen: shared as the session starts (in the background) and again as it
# ends, when it changed during the session.
wallpaper=/opt/hp-os/device/hp-os-login-wallpaper
[[ ! -x "$wallpaper" ]] || ( timeout 120 /usr/bin/python3 -I "$wallpaper" share >/dev/null 2>&1 & )
# Not exec: this script must outlive the session to hand SDDM a clean status.
"$own/hp-os-session"
status=$?
# Signing out goes straight to the login screen: the share at the end runs beside it (in its own session, so it
# outlives this script), and can never hold the screen black while it converts the picture.
[[ ! -x "$wallpaper" ]] || /usr/bin/setsid -f /usr/bin/timeout 20 /usr/bin/python3 -I "$wallpaper" share </dev/null >/dev/null 2>&1 || true
finish $status "HP-OS session"
EOF
bash -n "$target.new"
chmod 755 "$target.new"
mv "$target.new" "$target"
echo "Installed $target (previous version: $backup)."

# Accounts created later run the same setup at their first HP-OS login.
# One account that can't be updated now (its disk quota, a broken file of its own) mustn't fail the whole
# update and roll it back for everyone: it keeps its working desktop and is set up again at its next sign-in
# (hp-os-account-setup --needed). Only when no account could be updated is the update itself at fault.
tried=0 failed=0
while IFS=: read -r name _ uid _ _ directory shell; do
    [[ $uid -ge 1000 && $uid -le 60000 && "$directory" == "/home/$name" && "$shell" != */nologin && "$shell" != */false ]] || continue
    tried=$((tried + 1))
    if ! "$repo/goran/installer/hp-os-user-apply.sh" "$name"; then
        failed=$((failed + 1))
        echo "The desktop of $name couldn't be updated now; it is set up again when $name next signs in." >&2
        logger -t hp-os-update "account $name not updated; retried at its next sign-in" 2>/dev/null || true
    fi
done < <(getent -s files passwd)
if [[ $tried -gt 0 && $failed -eq $tried ]]; then
    echo "No account could be updated." >&2
    exit 1
fi
exit 0
