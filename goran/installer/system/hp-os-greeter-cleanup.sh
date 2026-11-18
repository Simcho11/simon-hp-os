#!/bin/bash
# System part of HP-OS multi-user: make the HP-OS login screen's session really end after a login,
# so "Switch user" can start a fresh login screen.
#
# Why: SDDM's SwitchToGreeter first looks for an existing login-screen (sddm-greeter) session and,
# if one exists, only switches to it. The login screen left an accessibility bus (at-spi
# dbus-daemon) running, which kept its finished session alive ("closing") on tty1. Switch user
# then jumped to that empty tty1 and the screen looked frozen (Ctrl+Alt+F2 got back).
#
#   sudo goran/installer/system/hp-os-greeter-cleanup.sh          install
#   sudo goran/installer/system/hp-os-greeter-cleanup.sh --undo   put everything back
# Takes effect on the next reboot.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

compositor=/opt/hp-os/login/greeter-compositor
sddm_conf=/etc/sddm.conf.d/90-hpos.conf
logind_conf=/etc/systemd/logind.conf.d/90-hpos-greeter.conf
suffix=.bak-before-greeter-cleanup

if [[ "${1:-}" == --undo ]]; then
    for f in "$compositor" "$sddm_conf"; do
        [[ -f "$f$suffix" ]] && cp -a "$f$suffix" "$f" && echo "Restored $f"
    done
    rm -f "$logind_conf" && echo "Removed $logind_conf"
    exit 0
fi

for f in "$compositor" "$sddm_conf"; do
    [[ -f "$f" ]] || { echo "Missing $f." >&2; exit 1; }
    [[ -f "$f$suffix" ]] || cp -a "$f" "$f$suffix"
done

# 1. Don't start the accessibility bus in the login screen (niri, its polkit agent, the greeter).
if ! grep -q 'NO_AT_BRIDGE' "$compositor"; then
    sed -i 's|^exec /usr/bin/dbus-run-session|# No accessibility bus: it outlives the login screen and keeps its session open.\nexport NO_AT_BRIDGE=1 GTK_A11Y=none QT_ACCESSIBILITY=0\n&|' "$compositor"
fi
if ! grep -q '^GreeterEnvironment=.*NO_AT_BRIDGE' "$sddm_conf"; then
    sed -i 's|^GreeterEnvironment=.*|&,NO_AT_BRIDGE=1,QT_ACCESSIBILITY=0|' "$sddm_conf"
fi

# 2. Safety net: when a login-screen session ends, logind stops whatever the sddm account left in
#    it. Limited to that account; everyone else's processes are untouched.
mkdir -p "$(dirname "$logind_conf")"
cat > "$logind_conf" <<'EOF'
# HP-OS: end the login screen's session completely after a login (hp-os-greeter-cleanup.sh).
[Login]
KillUserProcesses=yes
KillOnlyUsers=sddm
EOF

sh -n "$compositor"
echo "Login screen: $(grep -c NO_AT_BRIDGE "$compositor") line(s) in $compositor"
grep '^GreeterEnvironment' "$sddm_conf"
echo "Wrote $logind_conf"
echo "Done. Reboot to use it. Undo: sudo $0 --undo"
