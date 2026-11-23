"""Merge hp-snap's house defaults (defaults.json) into an HP-OS config.json.

Usage: apply-defaults.py DEFAULTS_JSON CONFIG_JSON [MARKER]
Values from DEFAULTS_JSON win; everything else in CONFIG_JSON is kept. With MARKER, it runs only
once per account (the marker file records it), so later changes the user makes are never undone.
A missing CONFIG_JSON is left alone: HP-OS creates it from the default config, which already
has these values built in. So is one that can't be read as HP-OS settings (empty, cut short, not
JSON): it stays exactly as it is and is not marked, so the defaults go in once it is whole again.
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


def load_config(target):
    # This runs in every Home Manager update and as the session starts: a damaged config.json
    # must not stop either.
    try:
        config = json.loads(target.read_text())
    except (OSError, ValueError, RecursionError) as error:
        print(f"apply-defaults: left {target} as it is ({error})", file=sys.stderr)
        return None
    if not isinstance(config, dict):
        print(f"apply-defaults: left {target} as it is (not a JSON object)", file=sys.stderr)
        return None
    return config


def main(argv):
    defaults = json.loads(pathlib.Path(argv[1]).read_text())
    target = pathlib.Path(argv[2])
    marker = pathlib.Path(argv[3]) if len(argv) > 3 else None
    if marker and marker.exists():
        return 0
    if not target.exists():
        return 0
    config = load_config(target)
    if config is None:
        return 0
    config = merge(config, defaults)
    fd, temporary = tempfile.mkstemp(prefix="." + target.name, dir=target.parent)
    with os.fdopen(fd, "w") as stream:
        json.dump(config, stream, indent=4)
        stream.write("\n")
    os.chmod(temporary, target.stat().st_mode & 0o777)
    os.replace(temporary, target)
    if marker:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("applied\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
