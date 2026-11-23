#!/usr/bin/env python3
"""Add an app to an account's Dock, once.

Usage: dock-add-once.py CONFIG_JSON APP AFTER MARKER

Puts APP in dock.pinnedApps right after AFTER (or first, if AFTER isn't pinned). It runs once per
account (MARKER records it), so someone who later takes the app off their Dock keeps it off.
A missing CONFIG_JSON means a new account, which gets the app from its default config: it is only marked.
"""
import json
import os
from pathlib import Path
import sys
import tempfile


def add_once(path, app, after, marker):
    if marker.exists():
        return False
    if not path.exists():
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text('applied\n')
        return False
    config = json.loads(path.read_text())
    dock = config.setdefault('dock', {})
    pins = list(dock.get('pinnedApps') or [])
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
