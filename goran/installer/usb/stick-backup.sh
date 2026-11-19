#!/bin/bash
# Keep a copy of an HP-OS USB installer stick, and put it back later.
#
#   sudo goran/installer/usb/stick-backup.sh save               copy the plugged-in stick into your home folder
#   sudo goran/installer/usb/stick-backup.sh restore FOLDER     erase the plugged-in stick and put that copy back
#   sudo goran/installer/usb/stick-backup.sh write IMAGE [SHA256]
#                                                     erase the plugged-in stick and write an installer image to it
#                                                     (IMAGE - reads it from a pipe; SHA256 is the image's expected checksum)
#
# Only the used parts are saved, compressed. A copy can hold the stick's update key, so it stays private
# (readable only by you) and on this computer.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
stop() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || stop "run this with sudo."
owner="${SUDO_USER:-}"
[[ -n "$owner" && "$owner" != root ]] || stop "run this with sudo from your own account."
home=$(getent passwd "$owner" | cut -d: -f6)

# ── Exactly one USB stick, never the disk this computer runs from ──
sticks=()
while read -r name transport removable; do
    [[ "$transport" == usb && "$removable" == 1 ]] && sticks+=("$name")
done < <(lsblk -dnpo NAME,TRAN,RM)
[[ ${#sticks[@]} -gt 0 ]] || stop "plug in the USB stick."
[[ ${#sticks[@]} -eq 1 ]] || stop "more than one USB stick is plugged in. Leave only the one you mean."
stick=${sticks[0]}
[[ "/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")" != "$stick" ]] || stop "that is the disk this computer is running from."
part() { lsblk -lnpo NAME "$stick" | sed -n "$(( $1 + 1 ))p"; }
description="$(lsblk -dno VENDOR,MODEL "$stick" | xargs) ($(lsblk -dno SIZE "$stick" | xargs))"
for p in $(lsblk -lnpo NAME "$stick" | tail -n +2); do
    ! findmnt -rno TARGET -S "$p" >/dev/null || stop "$p is open. Close any windows showing the stick and try again."
done

case "${1:-}" in
save)
    boot=$(part 1); system=$(part 2)
    [[ "$(blkid -o value -s LABEL "$boot")" == HPOS-BOOT && "$(blkid -o value -s LABEL "$system")" == HPOS-SYSTEM ]] \
        || stop "this stick isn't an HP-OS installer."
    used=$(dumpe2fs -h "$system" 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Free blocks/{f=$2} /^Block size/{s=$2} END{printf "%d", (c-f)*s}')
    free=$(df --output=avail -B1 "$home" | tail -1)
    # A compressed copy is usually well under half the used space. Keep 8 GB free for the computer itself.
    need=$(( used * 6 / 10 + 8 * 1000 ** 3 ))
    say "The stick has $(( used / 1000 ** 3 )) GB in use; this computer has $(( free / 1000 ** 3 )) GB free."
    [[ $free -gt $need ]] || stop "not enough free space here for a safe copy (about $(( need / 1000 ** 3 )) GB is needed). Nothing was changed."
    folder="$home/HP-OS USB backups/$(date +%Y-%m-%d)-installer-from-$(basename "$stick")"
    [[ ! -e "$folder" ]] || stop "$folder already exists. Nothing was changed."
    install -d -m 700 -o "$owner" -g "$owner" "$home/HP-OS USB backups"
    install -d -m 700 -o "$owner" -g "$owner" "$folder"
    say "1 of 4: Saving the partition layout"
    sgdisk --backup="$folder/partitions.gpt" "$stick" >/dev/null
    sfdisk -d "$stick" > "$folder/partitions.txt"
    say "2 of 4: Saving the startup partition"
    dd if="$boot" bs=4M status=none | zstd -q -T0 -3 -o "$folder/boot.vfat.zst"
    say "3 of 4: Saving HP-OS (this takes a while)"
    e2fsck -fn "$system" >/dev/null 2>&1 || stop "the stick's system partition has errors, so it wasn't copied."
    e2image -ra -p "$system" - | zstd -q -T0 -3 -o "$folder/system.ext4.zst"
    say "4 of 4: Checking the copy"
    zstd -tq "$folder/boot.vfat.zst" "$folder/system.ext4.zst"
    (cd "$folder" && sha256sum partitions.gpt boot.vfat.zst system.ext4.zst > SHA256SUMS)
    cat > "$folder/README.txt" <<EOF
HP-OS USB installer copy, saved $(date '+%Y-%m-%d %H:%M') from $description.
It may hold the stick's update key: keep it private and on this computer.

To put it back on a stick of at least the same size (this erases that stick):
  sudo goran/installer/usb/stick-backup.sh restore "$folder"
EOF
    chown -R "$owner:$owner" "$folder"; chmod 600 "$folder"/*
    say "Saved: $folder ($(du -sh "$folder" | cut -f1))"
    ;;
restore)
    folder="${2:-}"
    [[ -f "$folder/SHA256SUMS" ]] || stop "give the folder of a saved copy."
    (cd "$folder" && sha256sum -c --quiet SHA256SUMS) || stop "the saved copy is damaged. Nothing was changed."
    say "This erases everything on $description and puts back the copy from $folder."
    read -r -p "Type ERASE to continue: " answer
    [[ "$answer" == ERASE ]] || stop "nothing was changed."
    wipefs --all --force "$stick" >/dev/null
    sgdisk --load-backup="$folder/partitions.gpt" "$stick" >/dev/null
    blockdev --rereadpt "$stick"; udevadm settle
    say "1 of 2: Putting back the startup partition"
    zstd -dcq "$folder/boot.vfat.zst" | dd of="$(part 1)" bs=4M conv=fsync status=none
    say "2 of 2: Putting back HP-OS (this takes a while)"
    zstd -dcq "$folder/system.ext4.zst" | dd of="$(part 2)" bs=4M conv=sparse,fsync status=none
    e2fsck -fn "$(part 2)" >/dev/null 2>&1 || stop "the restored stick didn't check out. Try again or use another stick."
    sync
    say "The stick is back as it was. You can remove it."
    ;;
write)
    source="${2:-}"; expected="${3:-}"
    [[ "$source" == - || -f "$source" ]] || stop "give the image file, or - to read it from a pipe."
    say "This erases everything on $description and writes the new installer to it."
    read -r -p "Type ERASE to continue: " answer </dev/tty
    [[ "$answer" == ERASE ]] || stop "nothing was changed."
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    wipefs --all --force "$stick" >/dev/null
    say "1 of 2: Writing the installer (this takes a while)"
    { if [[ "$source" == - ]]; then cat; else cat "$source"; fi; } \
        | tee >(sha256sum | cut -d' ' -f1 > "$work/written.sha") >(wc -c > "$work/written.size") \
        | dd of="$stick" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
    for _ in $(seq 60); do [[ -s "$work/written.sha" && -s "$work/written.size" ]] && break; sleep 1; done
    written=$(cat "$work/written.sha"); size=$(cat "$work/written.size")
    [[ $size -gt 1000000000 ]] || stop "the installer image was too small ($size bytes). The stick needs writing again."
    [[ -z "$expected" || "$written" == "$expected" ]] || stop "the image arrived damaged. The stick needs writing again."
    say "2 of 2: Checking the stick"
    sync; echo 3 > /proc/sys/vm/drop_caches
    [[ "$(head -c "$size" "$stick" | sha256sum | cut -d' ' -f1)" == "$written" ]] \
        || stop "what is on the stick doesn't match the image. Try writing again, or use another stick."
    # The image is smaller than the stick: move the partition table's spare copy to the stick's real end.
    sgdisk -e "$stick" >/dev/null 2>&1 || true
    blockdev --rereadpt "$stick" 2>/dev/null || true
    say "The installer is on the stick and checked. You can remove it."
    ;;
*)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
