#!/usr/bin/env python3
"""Point a COSMIC Files dock pin at HP-OS Files, retaining the user's other HP-OS settings.

HP-OS Files (Dolphin) is the one file manager. Accounts that pinned COSMIC Files
get HP-OS Files in the same place; nothing else in the dock changes.
"""
import json
import os
from pathlib import Path
import tempfile
import sys


def update(path):
    if not path.exists():
        return False
    config = json.loads(path.read_text())
    dock = config.setdefault('dock', {})
    old = dock.get('pinnedApps', [])
    files = 'org.kde.dolphin'
    pins = []
    for app in old:
        app = files if app in ('com.system76.CosmicFiles', 'com.system76.CosmicFiles.desktop') else app
        if app not in pins:
            pins.append(app)
    if pins == old:
        return False
    dock['pinnedApps'] = pins
    fd, temporary = tempfile.mkstemp(prefix='.files-dock-pin-', dir=path.parent)
    try:
        os.fchmod(fd, path.stat().st_mode & 0o777)
        with os.fdopen(fd, 'w') as stream:
            json.dump(config, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


if __name__ == '__main__':
    update(Path(sys.argv[1]))
