#!/bin/bash
# Create the HP-OS USB installer from the newest published release.
#
#   sudo goran/installer/usb/make-usb.sh           erase the USB stick and build the installer on it
#   goran/installer/usb/make-usb.sh --check        look at everything first and change nothing
#
# People's accounts, files, Wi-Fi networks and sign-ins are never copied (prepare-system.py).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
kernel=7.0.14-2020-n1x-hibernate
minimum_gb=64
check=false
[[ "${1:-}" != --check ]] || check=true

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
stop() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

owner="${SUDO_USER:-$(id -un)}"
[[ "$owner" != root ]] || stop "run this with sudo from your own account."
as_owner() { if [[ $EUID -eq 0 ]]; then sudo -u "$owner" -H "$@"; else "$@"; fi; }

# ── Which USB stick ──
sticks=()
while read -r name transport removable bytes; do
    [[ "$transport" == usb && "$removable" == 1 && "$bytes" -ge $((minimum_gb * 1000000000)) ]] && sticks+=("$name")
done < <(lsblk -dnbpo NAME,TRAN,RM,SIZE)
[[ ${#sticks[@]} -gt 0 ]] || stop "plug in a USB stick of at least $minimum_gb GB."
[[ ${#sticks[@]} -eq 1 ]] || stop "more than one USB stick is plugged in. Leave only the one to erase."
stick=${sticks[0]}
root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
[[ "/dev/$root_disk" != "$stick" ]] || stop "that is the disk this laptop is running from."
description="$(lsblk -dno VENDOR,MODEL "$stick" | xargs) ($(lsblk -dno SIZE "$stick" | xargs))"

# ── Only a published release goes on the stick ──
as_owner "$repo/goran/installer/release/hp-os-publish" is-published \
    || stop "the code here isn't the newest published release. Publish it first."
[[ -r /boot/vmlinuz-$kernel && -d /usr/lib/modules/$kernel ]] || stop "this laptop's system files are missing."
free_kb=$(df --output=avail -k "$repo" | tail -1)
[[ $free_kb -gt 8000000 ]] || stop "free up at least 8 GB on this laptop first."

if $check; then
    echo "Ready: the installer would be written to $stick, $description."
    exit 0
fi
[[ $EUID -eq 0 ]] || stop "run this with sudo."

say "This erases everything on $description."
read -r -p "Type ERASE to continue: " answer
[[ "$answer" == ERASE ]] || stop "nothing was changed."

work=$(mktemp -d /var/tmp/hp-os-usb.XXXXXX)
target=$work/stick
mkdir -p "$target"
finish() {
    umount -R "$target" 2>/dev/null || true
    rm -rf "$work"
}
trap finish EXIT

say "1 of 7: Matching this laptop to the published release"
snapshot=$work/release
mkdir -p "$snapshot"
chown "$owner" "$work" "$snapshot"
as_owner git -C "$repo" archive HEAD | tar -x -C "$snapshot"
chown -R "$owner" "$snapshot"
SUDO_USER=$owner "$snapshot/goran/installer/system/hp-os-add-user.sh" >"$work/install.log" 2>&1 \
    || { tail -20 "$work/install.log"; stop "this laptop couldn't be matched to the release."; }

say "2 of 7: Preparing the USB stick"
installer=$(as_owner nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths "path:$snapshot#hp-os-usb-installer")
tools=$installer/tools/bin
for part in "$stick"?*; do umount "$part" 2>/dev/null || true; done
"$tools/wipefs" --all --force "$stick" >/dev/null
"$tools/sgdisk" --zap-all "$stick" >/dev/null
"$tools/sgdisk" -n 1:2048:+4G -t 1:EF00 -c 1:HPOS-BOOT -n 2:0:0 -t 2:8300 -c 2:HPOS-SYSTEM "$stick" >/dev/null
blockdev --rereadpt "$stick"; udevadm settle
for part in "${stick}1" "${stick}2"; do umount "$part" 2>/dev/null || true; done
"$tools/mkfs.vfat" -F 32 -n HPOS-BOOT "${stick}1" >/dev/null
"$tools/mkfs.ext4" -F -q -L HPOS-SYSTEM -O ^has_journal "${stick}2"
mount -o noatime "${stick}2" "$target"
system=$target/system
mkdir -p "$system"

say "3 of 7: Copying HP-OS (this takes a while)"
"$tools/rsync" -aHAXx --numeric-ids --info=progress2 --no-inc-recursive \
    --exclude=/nix/\* --exclude=/home/\* --exclude=/root/\* --exclude=/tmp/\* --exclude=/var/tmp/\* --exclude=/var/log/\* \
    --exclude=/swap.img --exclude=/lost+found --exclude=/var/cache/apt/\* --exclude=/var/lib/snapd/cache/\* \
    --exclude=/var/lib/waydroid --exclude=/media/\* --exclude=/mnt/\* --exclude=/boot/efi/\* / "$system/"
mkdir -p "$system/boot/efi/EFI"
cp -r /boot/efi/EFI/ubuntu /boot/efi/EFI/Boot "$system/boot/efi/EFI/"
[[ ! -d /boot/efi/EFI/HP ]] || cp -r /boot/efi/EFI/HP "$system/boot/efi/EFI/"

say "4 of 7: Removing everything personal"
/usr/bin/python3 -I "$here/prepare-system.py" "$system"

say "5 of 7: Copying the apps (this takes a while)"
nixx() { nix --extra-experimental-features 'nix-command flakes' "$@"; }
account="((builtins.getFlake \"path:$snapshot\").lib.hpOsAccount \"hposnewperson\").activationPackage"
as_owner nix --extra-experimental-features 'nix-command flakes' build --no-link --impure --expr "$account"
recipe=$(as_owner nix-instantiate --impure --expr "$account" 2>/dev/null | tail -1)
list=$work/store-paths
{
    nix-store -qR --include-outputs "$recipe"
    for profile in hp-os-accounts hp-os-add-user hp-os-airdrop; do
        [[ ! -e /nix/var/nix/profiles/$profile ]] || nix-store -qR "$(readlink -f /nix/var/nix/profiles/$profile)"
    done
    for root in /nix/var/nix/gcroots/hp-os-brightness /nix/var/nix/gcroots/hp-os-greeter-niri /nix/var/nix/gcroots/owly/*; do
        [[ ! -e $root ]] || nix-store -qR "$(readlink -f "$root")"
    done
    grep -rhoIE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+' "$system/opt" "$system/etc" "$system/usr/share/polkit-1" \
        "$system/usr/share/dbus-1" "$system/usr/local" 2>/dev/null | sort -u | while read -r path; do
        [[ ! -e $path ]] || nix-store -qR "$path"
    done
    find "$system/opt" "$system/etc" "$system/usr/share" -maxdepth 6 -type l -lname '/nix/store/*' -printf '%l\n' 2>/dev/null \
        | sed -E 's#^(/nix/store/[^/]+).*#\1#' | sort -u | while read -r path; do [[ ! -e $path ]] || nix-store -qR "$path"; done
} | sort -u > "$list"
nixx copy --no-check-sigs --to "local?root=$system" --stdin < "$list"
chown root:nixbld "$system/nix/store"; chmod 1775 "$system/nix/store"
profiles=$system/nix/var/nix/profiles; roots=$system/nix/var/nix/gcroots
mkdir -p "$profiles" "$roots/owly"
ln -sfn /nix/var/nix/profiles "$roots/profiles"
for profile in hp-os-accounts hp-os-add-user hp-os-airdrop; do
    [[ -e /nix/var/nix/profiles/$profile ]] || continue
    ln -sfn "$(readlink -f /nix/var/nix/profiles/$profile)" "$profiles/$profile-1-link"
    ln -sfn "$profile-1-link" "$profiles/$profile"
done
for root in hp-os-brightness hp-os-greeter-niri; do
    [[ ! -e /nix/var/nix/gcroots/$root ]] || ln -sfn "$(readlink -f /nix/var/nix/gcroots/$root)" "$roots/$root"
done
for root in /nix/var/nix/gcroots/owly/*; do
    [[ ! -e $root ]] || ln -sfn "$(readlink -f "$root")" "$roots/owly/$(basename "$root")"
done

say "6 of 7: Connecting updates and checking the result"
"$repo/goran/installer/release/hp-os-publish" image "$system"
flake=$(sed -n 's/^ *export HP_OS_PROFILE_FLAKE=//p' "$(readlink -f /nix/var/nix/profiles/hp-os-accounts)/bin/hp-os-account-setup")
offline=$(HOME=$work XDG_CACHE_HOME=$work/cache nix --extra-experimental-features 'nix-command flakes' build --offline --dry-run \
    --store "local?root=$system" --impure --expr "((builtins.getFlake \"$flake\").lib.hpOsAccount \"hposnewperson\").activationPackage" 2>&1) \
    || { echo "$offline" | tail -20; stop "a new account couldn't be set up without internet."; }
! grep -q 'will be fetched\|will be downloaded' <<<"$offline" || { echo "$offline" | tail -20; stop "some apps are missing from the installer."; }

say "7 of 7: Making the USB stick bootable"
boot=$work/boot
mkdir -p "$boot"
mount "${stick}1" "$boot"
mkdir -p "$boot/EFI/BOOT" "$boot/hpos"
cat > "$work/grub.cfg" <<GRUB
set timeout=0
set gfxpayload=keep
search --no-floppy --label HPOS-BOOT --set=root
linux /hpos/vmlinuz quiet loglevel=0 fbcon=nodefer console=tty0 vt.global_cursor_default=0 "acpi_osi=!Windows 2022" modprobe.blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidiafb rdinit=/init
initrd /hpos/installer.cpio.zst /hpos/modules.cpio.zst
boot
GRUB
grub-mkstandalone -O arm64-efi --modules="part_gpt fat ext2 search search_label linux normal configfile efi_gop all_video gzio" \
    -o "$boot/EFI/BOOT/BOOTAA64.EFI" "boot/grub/grub.cfg=$work/grub.cfg"
cp "/boot/vmlinuz-$kernel" "$boot/hpos/vmlinuz"
cp "$installer/installer.cpio.zst" "$boot/hpos/installer.cpio.zst"
(cd /usr && { printf 'lib\0lib/modules\0'; find "lib/modules/$kernel" -path '*/kernel/drivers/gpu/*' -prune -o -print0; } \
    | "$tools/cpio" --null --quiet -H newc -o | zstd -q -T0 -6) > "$boot/hpos/modules.cpio.zst"
umount "$boot"
sync
umount "$target"
sync
say "Your HP-OS USB stick is ready. You can remove it."
