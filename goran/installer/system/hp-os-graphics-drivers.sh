#!/bin/bash
# The graphics drivers the Nix desktop and login screen use (/run/opengl-driver), kept in step with the desktop.
#
#   sudo goran/installer/system/hp-os-graphics-drivers.sh
#
# Intel laptops only. Their drivers (Mesa) come from the desktop itself: the install points
# /etc/tmpfiles.d/non-nixos-gpu.conf at that version's drivers (build-image.sh), and an update that brings a newer
# desktop brings newer drivers too, which Home Manager says must then be pointed at. This does that, from the next
# start (the running session keeps the drivers it started with). ARM laptops are left alone: their NVIDIA drivers must
# match the system's own kernel driver, which this doesn't change.
# Never fails the update; with anything unexpected it leaves the link as it was.
set -uo pipefail
# HP_OS_TEST_ROOT: a fake root folder, for goran/installer/tests (passwd, links and the store all inside it).
root="${HP_OS_TEST_ROOT:-}"
[[ -n "$root" || $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ "${HP_OS_TEST_MACHINE:-$(uname -m)}" == x86_64 ]] || exit 0

link=$root/etc/tmpfiles.d/non-nixos-gpu.conf
[[ -L "$link" ]] || exit 0        # Not set up by the HP-OS installer: not ours to change.
current=$(readlink "$link")

# The drivers of an account's desktop as it is now (each account has the same ones; the first that has them is used).
wanted=""
while IFS=: read -r name _ uid _ _ directory _; do
    [[ $uid -ge 1000 && $uid -le 60000 && "$directory" == "/home/$name" ]] || continue
    setup="$root$directory/.local/state/nix/profiles/home-manager/home-path/bin/non-nixos-gpu-setup"
    [[ -f "$setup" ]] || continue
    wanted=$(grep -oE '/nix/store/[a-z0-9]{32}-non-nixos-gpu/lib/tmpfiles.d/non-nixos-gpu.conf' "$setup" | head -n 1)
    [[ -n "$wanted" ]] && break
done < <(if [[ -n "$root" ]]; then cat "$root/etc/passwd"; else getent -s files passwd; fi)

[[ -n "$wanted" && "$wanted" != "$current" ]] || exit 0
# Only a complete driver set: the file names the drivers' folder, and that folder holds Mesa's EGL and DRI drivers.
drivers=$(grep -oE '/nix/store/[a-z0-9]{32}-non-nixos-gpu' "$root$wanted" | head -n 1)
if [[ ! -s "$root$wanted" || -z "$drivers" || ! -d "$root$drivers/lib" ]] || ! ls "$root$drivers"/lib/libEGL_mesa.so* >/dev/null 2>&1; then
    echo "The new graphics drivers look incomplete; kept the ones in use." >&2
    exit 0
fi
# The old drivers stay until the next update (a garbage collection root follows the link), so going back is possible.
mkdir -p "$root/nix/var/nix/gcroots"
ln -sfn "$current" "$root/nix/var/nix/gcroots/hp-os-graphics-previous"
ln -sfn "$wanted" "$link.new" && mv -Tf "$link.new" "$link"
ln -sfn /etc/tmpfiles.d/non-nixos-gpu.conf "$root/nix/var/nix/gcroots/non-nixos-gpu.conf"
echo "Graphics drivers updated (from the next start)."
exit 0
