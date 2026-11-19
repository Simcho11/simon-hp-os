#!/bin/bash
# Lets the HP logo appear early in startup (on the basic display, before the graphics driver loads) instead of after
# a long black screen. Only on laptops made with the HP-OS USB installer, whose startup files it recognises exactly;
# any other laptop's startup is left alone.
#
#   hp-os-boot-splash.sh [ROOT]
set -euo pipefail
root="${1:-}"
script="$root/etc/grub.d/10_hp_os"
menu="$root/boot/grub/grub.cfg"
backup="$root/var/lib/hp-os/startup-backup"
[[ -f "$script" && -f "$menu" ]] || exit 0
grep -q "^menuentry 'HP-OS' --id hp-os {" "$menu" || exit 0
for file in "$script" "$menu"; do
    grep -q 'plymouth\.use-simpledrm=0' "$file" || continue
    new="$file.hp-os-new"
    sed 's/plymouth\.use-simpledrm=0/plymouth.use-simpledrm=1/' "$file" > "$new"
    # Exactly that one setting on one line changes, or nothing does.
    if [[ $(diff "$file" "$new" | grep -c '^[<>]') -ne 2 ]] || ! grep -q 'plymouth\.use-simpledrm=1' "$new"; then
        rm -f "$new"
        echo "Startup file $file looks different than expected; left unchanged." >&2
        continue
    fi
    mkdir -p "$backup"
    [[ -e "$backup/$(basename "$file")" ]] || cp -a "$file" "$backup/$(basename "$file")"
    chmod --reference="$file" "$new"
    chown --reference="$file" "$new" 2>/dev/null || true
    sync "$new"
    mv "$new" "$file"
done
sync
