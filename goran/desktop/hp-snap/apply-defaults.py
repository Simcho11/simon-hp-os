"""Merge hp-snap's house defaults (defaults.json) into an HP-OS config.json.

Usage: apply-defaults.py DEFAULTS_JSON CONFIG_JSON [MARKER]
Values from DEFAULTS_JSON win; everything else in CONFIG_JSON is kept. With MARKER, it runs only
once per account (the marker file records it), so later changes the user makes are never undone.
A missing CONFIG_JSON is left alone: HP-OS creates it from the default config, which already
has these values built in.
"""
import json
import os
import pathlib
import sys
import tempfile


def merge(base, extra):
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


defaults = json.loads(pathlib.Path(sys.argv[1]).read_text())
target = pathlib.Path(sys.argv[2])
marker = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
if marker and marker.exists():
    sys.exit(0)
if not target.exists():
    sys.exit(0)
config = merge(json.loads(target.read_text()), defaults)
fd, temporary = tempfile.mkstemp(prefix="." + target.name, dir=target.parent)
with os.fdopen(fd, "w") as stream:
    json.dump(config, stream, indent=4)
    stream.write("\n")
os.chmod(temporary, target.stat().st_mode & 0o777)
os.replace(temporary, target)
if marker:
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("applied\n")
