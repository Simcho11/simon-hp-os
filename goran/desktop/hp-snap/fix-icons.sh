#!/usr/bin/env bash
# Repair HP-OS's icon theme in a built package (usage: fix-icons.sh ICONS_DIR TRASH_SVG [TRASH_FULL_SVG]).
# Some icons are committed as small text files holding a relative path ("../originals/x.png",
# "bluetooth.png") instead of a link, so Qt shows its magenta placeholder for Trash, folders,
# Files and Settings. Turn each one back into the link it names, then add hp-snap's Trash icon.
set -euo pipefail
icons=$1 trash=$2 trash_full=${3:-}
fixed=0
while IFS= read -r -d '' file; do
  target=
  IFS= read -r target < "$file" || true
  case "$target" in
    */*[[:space:]]*|*[[:space:]]*|/*) continue ;;
    *.png|*.svg)
      if [[ -e "$(dirname "$file")/$target" ]]; then
        ln -sfn "$target" "$file"
        fixed=$((fixed + 1))
      fi ;;
  esac
done < <(find "$icons" -type f -size -200c -print0)
echo "fix-icons: $fixed placeholder files turned back into links"
install -m 0644 "$trash" "$icons/HP-OS/originals/trash.svg"
ln -sfn ../originals/trash.svg "$icons/HP-OS/256x256/hp-os-trash.svg"
# The same Trash with something in it, for the Dock, the desktop and Files.
if [[ -n "$trash_full" ]]; then
  install -m 0644 "$trash_full" "$icons/HP-OS/originals/trash-full.svg"
  ln -sfn ../originals/trash-full.svg "$icons/HP-OS/256x256/hp-os-trash-full.svg"
  ln -sfn ../originals/trash-full.svg "$icons/HP-OS/256x256/user-trash-full.svg"
fi
