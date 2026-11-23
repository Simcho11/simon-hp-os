#!/bin/bash
# Build the x86 HP-OS USB installer as a disk image, from a clean Ubuntu 26.04. Nothing is cloned from any laptop.
#
#   sudo goran/installer/usb/x86/build-image.sh WORK_FOLDER FONTS_FOLDER
#
# WORK_FOLDER   where the system is assembled; the finished hp-os-x86-usb.img is written here
# FONTS_FOLDER  the login screen's fonts (Inter, Rubik, Material Symbols)
#
# Each stage is remembered, so a stopped build continues where it left off.
# It never writes to a real disk: the result is an ordinary file.
set -euo pipefail
[[ $EUID -eq 0 && $# -eq 2 ]] || { echo "Usage: sudo $0 WORK_FOLDER FONTS_FOLDER" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
work=$1
fonts=$2
root=$work/rootfs
done_dir=$work/stages
image=$work/hp-os-x86-usb.img
suite=resolute
mirror=http://archive.ubuntu.com/ubuntu
root_uuid=d2c1c5bd-9c17-4517-abe7-90221e401acb   # Matches the installer (installer.py).
esp_id=B6AFFFE5
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
nixx() { nix --extra-experimental-features 'nix-command flakes' "$@"; }

say() { printf '\n=== %s\n' "$*"; }
stage() { [[ -e "$done_dir/$1" ]]; }
finished() { touch "$done_dir/$1"; }
unmount_all() {
    for point in dev/pts dev proc sys run; do
        mountpoint -q "$root/$point" && umount -l "$root/$point" || true
    done
}
trap unmount_all EXIT
mount_all() {
    mountpoint -q "$root/proc" || mount -t proc proc "$root/proc"
    mountpoint -q "$root/sys" || mount -t sysfs sysfs "$root/sys"
    mountpoint -q "$root/dev" || mount --bind /dev "$root/dev"
    mountpoint -q "$root/dev/pts" || mount -t devpts devpts "$root/dev/pts"
    mountpoint -q "$root/run" || mount -t tmpfs tmpfs "$root/run"
}
inside() { chroot "$root" /usr/bin/env -i PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"; }
mkdir -p "$work" "$done_dir"

# ── 1. A clean Ubuntu ──
if ! stage base; then
    say "1 of 6: Downloading a clean Ubuntu 26.04"
    rm -rf "$root"
    debootstrap --arch=amd64 --variant=minbase --components=main,restricted,universe,multiverse "$suite" "$root" "$mirror"
    finished base
fi
mount_all
if ! stage packages; then
    say "2 of 6: Installing the system packages"
    cat > "$root/etc/apt/sources.list" <<EOF
deb $mirror $suite main restricted universe multiverse
deb $mirror $suite-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $suite-security main restricted universe multiverse
EOF
    printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"; chmod 755 "$root/usr/sbin/policy-rc.d"
    echo 'do_symlinks = yes' > "$root/etc/kernel-img.conf"
    inside apt-get update -qq
    inside apt-get -y -qq full-upgrade
    # shellcheck disable=SC2046
    inside apt-get install -y -qq --no-install-recommends $(grep -v '^#' "$here/base-packages.txt")
    rm -f "$root/usr/sbin/policy-rc.d"
    inside apt-get clean
    finished packages
fi

# ── 2. The HP-OS desktop ──
snapshot=$work/flake
accounts=$work/out
mkdir -p "$accounts"
if ! stage desktop; then
    say "3 of 6: Building the HP-OS desktop"
    rm -rf "$snapshot"; mkdir -p "$snapshot"
    (cd "$repo" && tar --exclude=.git -cf - .) | tar -xf - -C "$snapshot"
    flake="path:$snapshot"
    nixx build --no-write-lock-file -o "$accounts/account" "$flake#homeConfigurations.hp-os-x86-standard.activationPackage"
    nixx build --no-write-lock-file -o "$accounts/setup" "$flake#packages.x86_64-linux.hp-os-account-setup"
    nixx build --no-write-lock-file -o "$accounts/theme" "$flake#packages.x86_64-linux.hp-os-login-theme"
    nixx build --no-write-lock-file -o "$accounts/add-user" "$flake#packages.x86_64-linux.hp-os-add-user"
    nixx build --no-write-lock-file -o "$accounts/usb" "$flake#packages.x86_64-linux.hp-os-usb-installer"
    finished desktop
fi

if ! stage store; then
    say "4 of 6: Copying the desktop into the system"
    account_flake=$(sed -n 's/^ *export HP_OS_PROFILE_FLAKE=//p' "$accounts/setup/bin/hp-os-account-setup")
    # A new account is finished offline at first sign-in, so its build recipe's parts come along.
    recipe=$(nix-instantiate --impure --expr "((builtins.getFlake \"$account_flake\").lib.hpOsAccount \"hposnewperson\").activationPackage" 2>/dev/null | tail -1)
    nixx build --no-link --impure --expr "((builtins.getFlake \"$account_flake\").lib.hpOsAccount \"hposnewperson\").activationPackage"
    {
        nix-store -qR --include-outputs "$recipe"
        for result in account setup theme add-user; do nix-store -qR "$(readlink -f "$accounts/$result")"; done
        grep -oE '/nix/store/[a-z0-9]{32}-source' "$accounts/setup/bin/hp-os-account-setup" | sort -u | xargs nix-store -qR
    } | sort -u > "$work/store-paths"
    nixx copy --no-check-sigs --to "local?root=$root" --stdin < "$work/store-paths"
    chown root:root "$root/nix/store"; chmod 1775 "$root/nix/store"
    finished store
fi

# ── 3. The system's own HP-OS parts ──
if ! stage system; then
    say "5 of 6: Setting up HP-OS"
    account=$(readlink -f "$accounts/account")
    shell=$(dirname "$(dirname "$(readlink -f "$account/home-path/bin/hp-os")")")
    niri=$(nix-store -qR "$account" | grep -E -- '-niri-hp-snap-hpos-[^/]*$' | while read -r path; do [[ -x $path/bin/niri ]] && echo "$path"; done | head -n 1)
    [[ -n "$niri" ]] || { echo "The login screen's compositor was not found." >&2; exit 1; }

    # Identity
    echo hp-os > "$root/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 hp-os\n::1 localhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
    sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="HP-OS"/' "$root/usr/lib/os-release"
    printf 'HP-OS\n' > "$root/etc/issue"; printf 'HP-OS\n' > "$root/etc/issue.net"
    echo 'en_US.UTF-8 UTF-8' > "$root/etc/locale.gen"; inside locale-gen >/dev/null
    echo 'LANG=en_US.UTF-8' > "$root/etc/default/locale"
    cat > "$root/etc/fstab" <<EOF
UUID=$root_uuid / ext4 errors=remount-ro 0 1
UUID=${esp_id:0:4}-${esp_id:4:4} /boot/efi vfat umask=0077 0 1
/swap.img none swap sw,pri=10 0 0
EOF
    install -d "$root/etc/netplan"
    printf 'network:\n  version: 2\n  renderer: NetworkManager\n' > "$root/etc/netplan/01-network-manager.yaml"
    chmod 600 "$root/etc/netplan/01-network-manager.yaml"

    # Memory compression: the system stays responsive with 8 GB of memory.
    cat > "$root/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
    printf 'vm.swappiness = 150\nvm.page-cluster = 0\n' > "$root/etc/sysctl.d/90-hp-os-memory.conf"

    # Nix
    install -d "$root/etc/nix"
    printf 'experimental-features = nix-command flakes\nsandbox = true\n' > "$root/etc/nix/nix.conf"
    roots=$root/nix/var/nix/gcroots; profiles=$root/nix/var/nix/profiles
    install -d "$roots" "$profiles"
    ln -sfn /nix/var/nix/profiles "$roots/profiles"
    publish() { ln -sfn "$2" "$profiles/$1-1-link"; ln -sfn "$1-1-link" "$profiles/$1"; }
    publish hp-os-accounts "$(readlink -f "$accounts/setup")"
    publish hp-os-add-user "$(readlink -f "$accounts/add-user")"
    ln -sfn "$niri" "$roots/hp-os-greeter-niri"
    # Graphics drivers for the Nix-built desktop and login screen, at /run/opengl-driver on every start
    # (what Home Manager's non-nixos-gpu-setup does on a running system).
    gpu=$(grep -oE '/nix/store/[a-z0-9]{32}-non-nixos-gpu/lib/tmpfiles.d/non-nixos-gpu.conf' "$account/home-path/bin/non-nixos-gpu-setup" | head -n 1)
    [[ -n "$gpu" && -e "$root$gpu" ]] || { echo "The desktop's graphics driver setup was not found." >&2; exit 1; }
    install -d "$root/etc/tmpfiles.d"
    ln -sfn "$gpu" "$root/etc/tmpfiles.d/non-nixos-gpu.conf"
    ln -sfn /etc/tmpfiles.d/non-nixos-gpu.conf "$roots/non-nixos-gpu.conf"

    # Login screen
    login=$root/opt/hp-os/login
    install -d "$login/themes/hpos" "$login/sessions" "$login/xsessions" "$root/opt/hp-os/niri-patch" "$root/etc/sddm.conf.d"
    ln -sfn "$niri" "$root/opt/hp-os/niri-patch/result-hpos"
    cp -r --no-preserve=mode,ownership "$(readlink -f "$accounts/theme")"/. "$login/themes/hpos"/
    cp -r --no-preserve=mode,ownership "$fonts"/. "$login/themes/hpos/fonts"/
    install -m 755 "$here/login/greeter-compositor" "$login/greeter-compositor"
    install -m 644 "$here/login/greeter.kdl" "$login/greeter.kdl"
    install -m 644 "$here/login/sddm.conf" "$root/etc/sddm.conf.d/90-hpos.conf"
    install -m 644 "$here/login/hpos.desktop" "$login/sessions/hpos.desktop"
    sed "s#@PACKAGING@#$shell/share/hp-os/packaging#" "$here/login/initialize-profile.py" > "$login/initialize-profile.py"
    chmod 755 "$login/initialize-profile.py"
    # The session script has one source: the one the ARM devices use.
    sed -n "/^cat > \"\$target.new\" <<'EOF'\$/,/^EOF\$/p" "$repo/goran/installer/system/hp-os-login-session.sh" | sed '1d;$d' > "$login/session"
    bash -n "$login/session"; chmod 755 "$login/session"
    install -Dm755 "$repo/goran/installer/system/hp-os-nix-group" "$root/etc/shadow-maint/useradd-post.d/hp-os-nix-group"
    install -d "$root/etc/systemd/logind.conf.d"
    printf '[Login]\nKillUserProcesses=yes\nKillOnlyUsers=sddm\n' > "$root/etc/systemd/logind.conf.d/90-hpos-greeter.conf"
    cat > "$root/usr/share/applications/hpos-add-user.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Add user
Exec=/nix/var/nix/profiles/hp-os-add-user/bin/hp-os-add-user %u
MimeType=x-scheme-handler/hpos-add-user;
NoDisplay=true
Terminal=false
EOF
    inside update-desktop-database -q /usr/share/applications

    # First-time setup, factory reset and updates: the same script as every HP-OS device.
    install -d "$root/opt/hp-os-build"
    cp -r "$repo/goran/installer/system" "$root/opt/hp-os-build/system"
    install -d "$root/opt/hp-os-build/bin"
    # Nothing is running inside this folder, so services are only marked to start.
    cat > "$root/opt/hp-os-build/bin/systemctl" <<'EOF'
#!/bin/sh
[ "$1" = daemon-reload ] && exit 0
[ "$1" = enable ] || exit 0
shift
for argument in "$@"; do [ "$argument" = --now ] || set -- "$@" "$argument"; shift; done
exec /usr/bin/systemctl --root=/ enable "$@"
EOF
    chmod 755 "$root/opt/hp-os-build/bin/systemctl"
    inside env PATH=/opt/hp-os-build/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin /opt/hp-os-build/system/hp-os-device-setup.sh
    # Ubuntu's daily security updates on (the kernel and startup parts held back), printing and printer discovery on.
    inside env PATH=/opt/hp-os-build/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin /opt/hp-os-build/system/hp-os-system-packages.sh
    rm -rf "$root/opt/hp-os-build"

    # Services
    ln -sfn /usr/lib/systemd/system/sddm.service "$root/etc/systemd/system/display-manager.service"
    echo /usr/bin/sddm > "$root/etc/X11/default-display-manager"
    inside systemctl --root=/ set-default graphical.target >/dev/null
    inside systemctl --root=/ enable NetworkManager.service bluetooth.service nix-daemon.socket >/dev/null

    # Startup
    install -d "$root/boot/efi/EFI/ubuntu" "$root/boot/efi/EFI/BOOT" "$root/boot/grub"
    cp "$root/usr/lib/shim/shimx64.efi.signed.latest" "$root/boot/efi/EFI/ubuntu/shimx64.efi"
    cp "$root/usr/lib/shim/mmx64.efi" "$root/boot/efi/EFI/ubuntu/mmx64.efi"
    cp "$root/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$root/boot/efi/EFI/ubuntu/grubx64.efi"
    # Some computers forget their startup entry; this path is the one they always look for.
    cp "$root/usr/lib/shim/shimx64.efi.signed.latest" "$root/boot/efi/EFI/BOOT/BOOTX64.EFI"
    cp "$root/usr/lib/shim/mmx64.efi" "$root/boot/efi/EFI/BOOT/mmx64.efi"
    cp "$root/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$root/boot/efi/EFI/BOOT/grubx64.efi"
    cat > "$root/boot/efi/EFI/ubuntu/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $root_uuid
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EOF
    cat > "$root/boot/grub/grub.cfg" <<EOF
set timeout=0
set gfxpayload=keep
search --no-floppy --fs-uuid --set=root $root_uuid
linux /boot/vmlinuz root=UUID=$root_uuid ro quiet splash
initrd /boot/initrd.img
boot
EOF
    inside update-initramfs -c -k all >/dev/null 2>&1 || inside update-initramfs -u -k all >/dev/null

    # A new device: no accounts, and its first start opens first-time setup.
    install -d "$root/etc/hp-os" "$root/var/lib/hp-os"
    echo "Made with the HP-OS USB installer." > "$root/etc/hp-os/standard-device"
    printf 'import QtQuick\nItem {}\n' > "$root/var/lib/hp-os/first-boot.qml"
    chmod 644 "$root/var/lib/hp-os/first-boot.qml"
    rm -f "$root/etc/ssh/ssh_host_"* "$root/var/lib/dbus/machine-id"
    : > "$root/etc/machine-id"
    rm -rf "$root/var/cache/apt/"* "$root/var/lib/apt/lists/"* "$root/tmp/"* "$root/var/tmp/"* "$root/var/log/"*
    finished system
fi
unmount_all
trap - EXIT

# ── 4. The USB image ──
say "6 of 6: Making the USB image"
usb=$(readlink -f "$accounts/usb")
kernel=$(basename "$(readlink -f "$root/boot/vmlinuz")"); kernel=${kernel#vmlinuz-}
modules=$work/modules.cpio.zst
(cd "$root/usr" && { printf 'lib\0lib/modules\0'; find "lib/modules/$kernel" -path '*/kernel/drivers/gpu/*' -prune -o -print0; } \
    | "$usb/tools/bin/cpio" --null --quiet -H newc -o | zstd -q -T0 -6) > "$modules"

# The stick's startup partition: what the computer's firmware reads first.
write_boot_partition() {
    local esp="$1@@1M"
    # 4 KB clusters: with larger ones a 1 GB FAT32 partition has too few clusters, and firmware ignores it.
    mkfs.vfat -F 32 -s 8 -S 512 -n HPOS-BOOT --offset 2048 "$1" $(( boot_mb * 1024 )) >/dev/null
    export MTOOLS_SKIP_CHECK=1
    mmd -i "$esp" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu ::/hpos
    mcopy -i "$esp" "$root/usr/lib/shim/shimx64.efi.signed.latest" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$esp" "$root/usr/lib/shim/mmx64.efi" ::/EFI/BOOT/mmx64.efi
    mcopy -i "$esp" "$root/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" ::/EFI/BOOT/grubx64.efi
    cat > "$work/usb-grub.cfg" <<'GRUB'
set timeout=0
set gfxpayload=keep
search --no-floppy --label HPOS-BOOT --set=root
linux /hpos/vmlinuz quiet loglevel=0 fbcon=nodefer console=tty0 vt.global_cursor_default=0 rdinit=/init
initrd /hpos/installer.cpio.zst /hpos/modules.cpio.zst
boot
GRUB
    mcopy -i "$esp" "$work/usb-grub.cfg" ::/EFI/ubuntu/grub.cfg
    mcopy -i "$esp" "$work/usb-grub.cfg" ::/EFI/BOOT/grub.cfg
    mcopy -i "$esp" "$root/boot/vmlinuz-$kernel" ::/hpos/vmlinuz
    mcopy -i "$esp" "$usb/installer.cpio.zst" ::/hpos/installer.cpio.zst
    mcopy -i "$esp" "$modules" ::/hpos/modules.cpio.zst
    fsck.vfat -n "$esp" >/dev/null 2>&1 || true
}
boot_mb=1024
# HPOS_BOOT_ONLY=IMAGE rewrites only the startup partition of an existing image.
if [[ -n "${HPOS_BOOT_ONLY:-}" ]]; then
    write_boot_partition "$HPOS_BOOT_ONLY"
    rm -f "$modules"
    say "The startup partition of $HPOS_BOOT_ONLY was rewritten"
    exit 0
fi
system_kb=$(du -sxk "$root" | cut -f1)
system_mb=$(( system_kb * 115 / 100 / 1024 + 2048 ))
total_mb=$(( 1 + boot_mb + system_mb + 1 ))
rm -f "$image"
# Both filesystems are written straight into the image at their partitions, so no extra copies need room.
truncate -s "${total_mb}M" "$image"
sgdisk --zap-all "$image" >/dev/null
sgdisk -n "1:2048:+${boot_mb}M" -t 1:EF00 -c 1:HPOS-BOOT -n "2:0:+${system_mb}M" -t 2:8300 -c 2:HPOS-SYSTEM "$image" >/dev/null
second=$(sgdisk -i 2 "$image" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')

# The system goes in a folder on the stick, as the installer expects.
staging=$work/stick
rm -rf "$staging"; mkdir -p "$staging"
mv "$root" "$staging/system"
restore() { [[ -d "$staging/system" ]] && mv "$staging/system" "$root"; }
trap restore EXIT
mkfs.ext4 -q -F -L HPOS-SYSTEM -O ^has_journal -E "root_owner=0:0,offset=$(( second * 512 ))" -d "$staging" "$image" "${system_mb}M"
restore; trap - EXIT

write_boot_partition "$image"
rm -f "$modules"
sgdisk --verify "$image" >/dev/null
say "The installer image is ready: $image ($(du -h "$image" | cut -f1))"
