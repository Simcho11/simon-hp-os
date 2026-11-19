#!/bin/bash
# First-time setup and factory reset for an HP-OS device. Run by hp-os-add-user.sh.
#
#   sudo goran/installer/system/hp-os-device-setup.sh                   install / update
#   sudo goran/installer/system/hp-os-device-setup.sh --undo            take it out again
#   sudo goran/installer/system/hp-os-device-setup.sh --mark-first-boot for a device image with no accounts:
#                                                                       its next start opens first-time setup
#
# Nothing here runs in the background: the sockets start a helper only when someone uses them.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
tool=/opt/hp-os/device/hp-os-device
units=/etc/systemd/system
state=/var/lib/hp-os

if [[ "${1:-}" == --undo ]]; then
    systemctl disable --now hp-os-factory-reset.socket hp-os-first-setup.socket hp-os-factory-wipe.service \
        hp-os-update.socket hp-os-update-check.timer hp-os-update-settle.service hp-os-login-wallpaper.socket 2>/dev/null || true
    rm -f "$units"/hp-os-update.socket "$units"/hp-os-update@.service "$units"/hp-os-update-job.service \
          "$units"/hp-os-update-check.service "$units"/hp-os-update-check.timer "$units"/hp-os-update-settle.service \
          "$units"/hp-os-login-wallpaper.socket "$units"/hp-os-login-wallpaper@.service
    rm -f "$units"/hp-os-factory-reset.socket "$units"/hp-os-factory-reset@.service "$units"/hp-os-first-setup.socket \
          "$units"/hp-os-first-setup@.service "$units"/hp-os-factory-wipe.service "$state/factory-reset-request"
    rm -rf /opt/hp-os/device
    systemctl daemon-reload
    echo "First-time setup and factory reset removed."
    exit 0
fi

if [[ "${1:-}" == --mark-first-boot ]]; then
    if getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { found = 1 } END { exit !found }'; then
        echo "This device has accounts on it, so it was left as it is." >&2
        exit 1
    fi
    install -d -m 755 "$state"
    printf 'import QtQuick\nItem {}\n' > "$state/first-boot.qml"
    chmod 644 "$state/first-boot.qml"
    echo "The next start opens first-time setup."
    exit 0
fi

/usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$here/hp-os-device.py"
install -d -m 755 /opt/hp-os/device "$state"
install -m 755 -o root -g root "$here/hp-os-device.py" "$tool"
/usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$here/hp-os-update.py"
install -m 755 -o root -g root "$here/hp-os-update.py" /opt/hp-os/device/hp-os-update
install -m 644 -o root -g root "$here/hp_os_release.py" /opt/hp-os/device/hp_os_release.py
/usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$here/hp-os-login-wallpaper.py"
install -m 755 -o root -g root "$here/hp-os-login-wallpaper.py" /opt/hp-os/device/hp-os-login-wallpaper
install -d -m 755 "$state/login-wallpapers"

# Downloads and builds run as this account, which can't touch anyone's files.
id hp-os-updater >/dev/null 2>&1 || useradd --system --home-dir "$state/update/home" --shell /usr/sbin/nologin hp-os-updater
! getent group nix-users >/dev/null || usermod -aG nix-users hp-os-updater
install -d -m 755 "$state/update" "$state/update/versions"
install -d -m 750 -o hp-os-updater -g hp-os-updater "$state/update/home"

cat > "$units/hp-os-factory-reset.socket" <<UNIT
[Unit]
Description=HP-OS factory reset requests

[Socket]
ListenStream=/run/hp-os/factory-reset.sock
SocketMode=0666
Accept=yes

[Install]
WantedBy=sockets.target
UNIT
cat > "$units/hp-os-factory-reset@.service" <<UNIT
[Unit]
Description=HP-OS factory reset request

[Service]
ExecStart=/usr/bin/python3 -I $tool request
StandardInput=socket
StandardOutput=journal
StandardError=journal
UNIT
cat > "$units/hp-os-factory-wipe.service" <<UNIT
[Unit]
Description=Erase this device (HP-OS factory reset)
ConditionPathExists=$state/factory-reset-request
After=local-fs.target
# Before the network and Bluetooth start, so they never load the saved networks and pairings it erases.
Before=display-manager.service systemd-user-sessions.service NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/python3 -I $tool wipe
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT
cat > "$units/hp-os-first-setup.socket" <<UNIT
[Unit]
Description=HP-OS first-time setup requests

[Socket]
ListenStream=/run/hp-os/first-setup.sock
SocketUser=root
SocketGroup=sddm
SocketMode=0660
Accept=yes

[Install]
WantedBy=sockets.target
UNIT
cat > "$units/hp-os-first-setup@.service" <<UNIT
[Unit]
Description=HP-OS first-time setup

[Service]
ExecStart=/usr/bin/python3 -I /nix/var/nix/profiles/hp-os-add-user/share/hp-os-add-user/accounts.py --first-boot
StandardInput=socket
StandardOutput=socket
StandardError=journal
UNIT
cat > "$units/hp-os-update.socket" <<UNIT
[Unit]
Description=HP-OS software update requests

[Socket]
ListenStream=/run/hp-os/update.sock
SocketMode=0666
Accept=yes

[Install]
WantedBy=sockets.target
UNIT
cat > "$units/hp-os-update@.service" <<UNIT
[Unit]
Description=HP-OS software update request

[Service]
ExecStart=/usr/bin/python3 -I /opt/hp-os/device/hp-os-update request
StandardInput=socket
StandardOutput=journal
StandardError=journal
UNIT
cat > "$units/hp-os-update-job.service" <<UNIT
[Unit]
Description=Install an HP-OS software update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -I /opt/hp-os/device/hp-os-update job
TimeoutStartSec=infinity
Nice=10
UNIT
cat > "$units/hp-os-update-check.service" <<UNIT
[Unit]
Description=Look for an HP-OS software update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -I /opt/hp-os/device/hp-os-update check
UNIT
# Each account's wallpaper on the login screen: the session shares it, this keeps the copy (only when asked).
cat > "$units/hp-os-login-wallpaper.socket" <<UNIT
[Unit]
Description=HP-OS login screen wallpapers

[Socket]
ListenStream=/run/hp-os/login-wallpaper.sock
SocketMode=0666
Accept=yes

[Install]
WantedBy=sockets.target
UNIT
cat > "$units/hp-os-login-wallpaper@.service" <<UNIT
[Unit]
Description=HP-OS login screen wallpaper from one account

[Service]
ExecStart=/usr/bin/python3 -I /opt/hp-os/device/hp-os-login-wallpaper serve
StandardInput=socket
StandardOutput=journal
StandardError=journal
TimeoutSec=60
UNIT
cat > "$units/hp-os-update-settle.service" <<UNIT
[Unit]
Description=Finish an HP-OS software update after its restart
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -I /opt/hp-os/device/hp-os-update settle

[Install]
WantedBy=multi-user.target
UNIT
cat > "$units/hp-os-update-check.timer" <<UNIT
[Unit]
Description=Look for HP-OS software updates once a day

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now hp-os-factory-reset.socket hp-os-first-setup.socket hp-os-update.socket hp-os-update-check.timer \
    hp-os-login-wallpaper.socket >/dev/null
systemctl enable hp-os-factory-wipe.service hp-os-update-settle.service >/dev/null

# Laptops made with the USB installer show the HP logo early in startup.
"$here/hp-os-boot-splash.sh"

# The login screen must survive a reset that removes every home folder.
niri=$(readlink -f /opt/hp-os/niri-patch/result-hpos)
[[ "$niri" != /nix/store/* ]] || ln -sfn "$niri" /nix/var/nix/gcroots/hp-os-greeter-niri
echo "First-time setup and factory reset are ready."
