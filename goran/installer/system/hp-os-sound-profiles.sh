#!/bin/bash
# The speaker and microphone profiles for each laptop's sound chip (Ubuntu's alsa-ucm-conf and alsa-topology-conf).
#
#   sudo goran/installer/system/hp-os-sound-profiles.sh
#
# Intel laptops installed before 2026-11-21 were made without them (the install skips Ubuntu's "recommended"
# extras), so newer Intel laptops show only "Dummy Output". Run by every update; does nothing once they're there.
# Never fails the update: without internet or with apt busy it says so and the next update tries again.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

# The ARM laptops' sound profiles came with their system and already include these.
[[ "$(uname -m)" == x86_64 ]] || exit 0
command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || exit 0

packages=(alsa-ucm-conf alsa-topology-conf)
missing=()
for package in "${packages[@]}"; do
    [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" == "install ok installed" ]] || missing+=("$package")
done
[[ ${#missing[@]} -gt 0 ]] || exit 0

echo "Adding the sound profiles: ${missing[*]}"
export DEBIAN_FRONTEND=noninteractive
install_them() {
    timeout 600 apt-get install -y -q --no-install-recommends -o DPkg::Lock::Timeout=120 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}" >/dev/null
}
# Installed laptops keep no package list, so fetch it when the packages aren't found in it.
if ! install_them; then
    timeout 300 apt-get update -q -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 || true
    install_them || { echo "The sound profiles couldn't be added now; the next update tries again." >&2; exit 0; }
fi

# Signed-in accounts pick them up without a restart.
for run in /run/user/[0-9]*; do
    [[ -d "$run" ]] || continue
    user=$(id -nu "${run##*/}" 2>/dev/null) || continue
    timeout 20 systemctl --machine="$user@.host" --user restart wireplumber >/dev/null 2>&1 || true
done
echo "Sound profiles added."
exit 0
