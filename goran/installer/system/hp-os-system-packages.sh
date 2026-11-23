#!/bin/bash
# The Ubuntu parts every HP-OS laptop needs, added to laptops installed without them. Run by every update; does
# nothing once they're there.
#
#   sudo goran/installer/system/hp-os-system-packages.sh
#
# Intel laptops are installed from a minimal Ubuntu without Ubuntu's "recommended" extras (base-packages.txt). Laptops
# installed before 2026-11 lack, depending on when: the sound profiles ("Dummy Output"), printing, realtime audio,
# firmware updates, Thunderbolt docks, Intel's thermal management and Ubuntu's security updates. ARM laptops came with
# all of them; there only the Chrome sandbox rule is checked.
# Never fails the update: without internet or with apt busy it says so and the next update tries again.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"

# Chrome (from Nix) runs its sandbox in a user namespace, which Ubuntu only allows a program AppArmor names. The ARM
# laptops' copy of this rule came with their system image; any laptop with AppArmor gets it from here.
if [[ -d /etc/apparmor.d && -x /usr/sbin/apparmor_parser ]] && ! cmp -s "$here/apparmor/chrome-nix" /etc/apparmor.d/chrome-nix; then
    install -m 644 -o root -g root "$here/apparmor/chrome-nix" /etc/apparmor.d/chrome-nix.new
    if /usr/sbin/apparmor_parser -Q -T /etc/apparmor.d/chrome-nix.new 2>/dev/null; then
        mv -f /etc/apparmor.d/chrome-nix.new /etc/apparmor.d/chrome-nix
        /usr/sbin/apparmor_parser -r -T -W /etc/apparmor.d/chrome-nix 2>/dev/null || true
    else
        rm -f /etc/apparmor.d/chrome-nix.new
        echo "The Chrome sandbox rule wasn't accepted by AppArmor; left as it was." >&2
    fi
fi

[[ "$(uname -m)" == x86_64 ]] || exit 0
command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || exit 0

# Kept in step with base-packages.txt, which new Intel laptops are installed with.
packages=(
    # Sound: the speaker and microphone profiles for each sound chip, and realtime priority for PipeWire (no crackling
    # in calls when the laptop is busy).
    alsa-ucm-conf alsa-topology-conf rtkit
    # Printing: network printers are found by themselves (AirPrint / IPP Everywhere), USB ones too (IPP over USB),
    # and HP's own drivers for older HP printers. Chrome prints through these.
    cups cups-browsed cups-filters ipp-usb avahi-daemon libnss-mdns hplip printer-driver-hpcups
    # Firmware updates (HP's included), Thunderbolt and USB4 docks, and Intel's thermal management.
    fwupd bolt thermald
    # Ubuntu's security updates, installed by themselves each day (the startup parts are held back, see below).
    unattended-upgrades
)

# Turns on Ubuntu's daily security updates. The kernel and the startup parts are held back: these laptops start from
# a single kernel with no menu to fall back on, so a kernel that didn't start would leave the laptop unable to start.
# They come with HP-OS updates instead, once there is a tested way back.
configure_security_updates() {
    [[ -x /usr/bin/unattended-upgrade ]] || return 0
    local auto=/etc/apt/apt.conf.d/20auto-upgrades hold=/etc/apt/apt.conf.d/51hp-os-hold-startup
    if [[ ! -f "$auto" ]] || ! grep -q 'Unattended-Upgrade "1"' "$auto"; then
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "$auto.new"
        mv -f "$auto.new" "$auto"
    fi
    cat > "$hold.new" <<'EOF'
// HP-OS (hp-os-system-packages.sh): the kernel and startup parts are not updated by themselves.
Unattended-Upgrade::Package-Blacklist {
    "linux-";
    "grub";
    "shim";
    "initramfs-tools";
    "intel-microcode";
    "amd64-microcode";
    "nix-bin";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    if cmp -s "$hold.new" "$hold"; then rm -f "$hold.new"; else mv -f "$hold.new" "$hold"; fi
}

missing=()
for package in "${packages[@]}"; do
    [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" == "install ok installed" ]] || missing+=("$package")
done

export DEBIAN_FRONTEND=noninteractive
apt_options=(-q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
# An install cut off earlier (the power, a timeout) is finished first, or apt refuses everything after it.
if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
    echo "Finishing an interrupted package install."
    timeout --kill-after=60 1800 dpkg --force-confdef --force-confold --configure -a >/dev/null 2>&1 || true
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Adding: ${missing[*]}"
    install_them() {
        # Generous: printing brings Ghostscript and HP's drivers. If it is ever stopped, the next run finishes it.
        timeout --kill-after=120 2400 apt-get install -y --no-install-recommends "${apt_options[@]}" "${missing[@]}" >/dev/null
    }
    # Installed laptops keep no package list, so fetch it when the packages aren't found in it (the first try's
    # "Unable to locate package" is expected then, and not shown).
    if ! install_them 2>/dev/null; then
        timeout 300 apt-get update "${apt_options[@]}" >/dev/null 2>&1 || true
        if ! install_them; then
            echo "These couldn't be added now; the next update tries again: ${missing[*]}" >&2
            configure_security_updates
            exit 0
        fi
    fi
    # Signed-in accounts pick up the sound profiles and realtime audio without a restart.
    for run in /run/user/[0-9]*; do
        [[ -d "$run" ]] || continue
        user=$(id -nu "${run##*/}" 2>/dev/null) || continue
        timeout 20 systemctl --machine="$user@.host" --user restart wireplumber >/dev/null 2>&1 || true
    done
    echo "Added: ${missing[*]}"
fi

# Printers on the network are found by name (the .local addresses AirPrint printers use).
if [[ -f /etc/nsswitch.conf ]] && ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf && [[ -e /lib/x86_64-linux-gnu/libnss_mdns4_minimal.so.2 ]]; then
    sed -i -E 's/^(hosts:[[:space:]]+files)([[:space:]])/\1 mdns4_minimal [NOTFOUND=return]\2/' /etc/nsswitch.conf
fi
# Printing and printer discovery on, whatever an earlier install left (both only start when something uses them).
for unit in cups.socket cups.path avahi-daemon.socket; do
    [[ -e "/usr/lib/systemd/system/$unit" || -e "/lib/systemd/system/$unit" ]] || continue
    systemctl enable "$unit" >/dev/null 2>&1 || true
done
for unit in cups-browsed.service avahi-daemon.service; do
    [[ -e "/usr/lib/systemd/system/$unit" || -e "/lib/systemd/system/$unit" ]] || continue
    systemctl enable "$unit" >/dev/null 2>&1 || true
done
configure_security_updates
exit 0
