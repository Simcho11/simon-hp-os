#!/usr/bin/env python3
"""Add an app to an account's Dock, once.

Usage: dock-add-once.py CONFIG_JSON APP AFTER MARKER

Puts APP in dock.pinnedApps right after AFTER (or first, if AFTER isn't pinned). It runs once per
account (MARKER records it), so someone who later takes the app off their Dock keeps it off.
A missing CONFIG_JSON means a new account, which gets the app from its default config: it is only marked.
A CONFIG_JSON that can't be read as HP-OS settings is left as it is and not marked, so a later run adds it.
"""
import json
import os
from pathlib import Path
import sys
import tempfile


def skip(path, reason):
    # This runs in every Home Manager update: a damaged config.json must not stop the rest of it.
    print(f'dock-add-once: left {path} as it is ({reason})', file=sys.stderr)
    return False


def add_once(path, app, after, marker):
    if marker.exists():
        return False
    if not path.exists():
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text('applied\n')
        return False
    try:
        config = json.loads(path.read_text())
    except (OSError, ValueError, RecursionError) as error:
        return skip(path, error)
    if not isinstance(config, dict):
        return skip(path, 'not a JSON object')
    dock = config.setdefault('dock', {})
    if not isinstance(dock, dict):
        return skip(path, 'dock is not an object')
    pinned = dock.get('pinnedApps') or []
    if not isinstance(pinned, list):
        return skip(path, 'dock.pinnedApps is not a list')
    pins = list(pinned)
    changed = False
    if not any(str(pin).lower() in (app.lower(), app.lower() + '.desktop') for pin in pins):
        place = pins.index(after) + 1 if after in pins else 0
        pins.insert(place, app)
        dock['pinnedApps'] = pins
        fd, temporary = tempfile.mkstemp(prefix='.dock-add-', dir=path.parent)
        try:
            os.fchmod(fd, path.stat().st_mode & 0o777)
            with os.fdopen(fd, 'w') as stream:
                json.dump(config, stream, indent=4, ensure_ascii=False)
                stream.write('\n')
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        changed = True
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text('applied\n')
    return changed


if __name__ == '__main__':
    add_once(Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]))
