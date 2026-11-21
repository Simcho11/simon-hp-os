#!/usr/bin/env python3
"""Set aside an unmanaged Trash launcher left by an earlier HP-OS build.

~/.local/share/applications/hp-os-trash.desktop was once written by hand and
pointed at a fixed older Files. Home Manager now provides that launcher, and it
refuses to replace a file it does not own. The old file is moved, never
deleted, into the migration folder, where the switch-back script finds it.
"""
import datetime
import os
from pathlib import Path
import shutil
import sys

LAUNCHER = "hp-os-trash.desktop"


def is_stale(path):
    if path.is_symlink() or not path.is_file():
        return False
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return False
    execs = [line for line in text.splitlines() if line.startswith("Exec=")]
    return any("/bin/hp-os-files" in line and "trash:/" in line for line in execs)


def main(applications, migration):
    path = Path(applications) / LAUNCHER
    if not is_stale(path):
        return 0
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = Path(migration) / "set-aside" / stamp
    backup.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup / LAUNCHER)
    os.unlink(path)
    with open(Path(migration) / "set-aside.log", "a") as log:
        log.write(f"{stamp}\t{path}\t{backup / LAUNCHER}\n")
    print(f"HP-OS Files: set aside the old {path} in {backup}")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
