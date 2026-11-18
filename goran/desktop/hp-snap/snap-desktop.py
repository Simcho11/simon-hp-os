"""Move HP-OS's first-login desktop icons onto the desktop grid (once per account).

Usage: snap-desktop.py DESKTOP_ITEMS_JSON MARKER
HP-OS seeds a new desktop at 24 + n*104 px, but the desktop grid starts at 0 (with hp-snap's
8 px grid its pitch is exactly 104 px). Only the seeded icons (hp-os-initial-*) still sitting at
their seeded spot are moved 24 px up and left; anything the user placed is left alone.
"""
import json
import os
import pathlib
import sys
import tempfile

path, marker = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
if marker.exists() or not path.exists():
    sys.exit(0)
try:
    data = json.loads(path.read_text())
except (OSError, ValueError):
    sys.exit(0)
items = data.get("items") if isinstance(data, dict) else None
if not isinstance(items, dict):
    sys.exit(0)

moved = 0
for item_id, item in items.items():
    if not item_id.startswith("hp-os-initial-") or not isinstance(item, dict):
        continue
    try:
        index = int(item_id.removeprefix("hp-os-initial-"))
    except ValueError:
        continue
    # Where HP-OS put this particular icon (initialize-config.py: six per column). An icon
    # anywhere else, even on another old seed position, was moved by the user and stays.
    seeded_x, seeded_y = 24 + (index // 6) * 104, 24 + (index % 6) * 104
    if item.get("x") == seeded_x and item.get("y") == seeded_y:
        item["x"], item["y"] = seeded_x - 24, seeded_y - 24
        moved += 1

if moved:
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")
    os.chmod(temporary, path.stat().st_mode & 0o777)
    os.replace(temporary, path)
marker.parent.mkdir(parents=True, exist_ok=True)
marker.write_text(f"moved {moved}\n")
