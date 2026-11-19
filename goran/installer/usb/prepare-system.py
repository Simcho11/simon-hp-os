#!/usr/bin/python3
"""Turn a copy of this laptop's system into a factory-fresh HP-OS: nobody's accounts, files or secrets.

  prepare-system.py STAGING   clean the copy at STAGING, then check that nothing personal is left
"""
import glob
import json
import os
from pathlib import Path
import re
import shutil
import sys

ERASED = """
home/* root/* root/.[!.]* tmp/* var/tmp/* var/log/* var/crash/* var/mail/* var/spool/mail/* var/cache/apt/*
var/lib/AccountsService/users/* var/lib/AccountsService/icons/*
var/lib/sddm/.local var/lib/sddm/.cache var/lib/sddm/.config var/lib/sddm/state.conf
var/lib/systemd/linger/* var/lib/systemd/coredump/* var/lib/systemd/random-seed var/lib/systemd/timers/*
var/lib/bluetooth/* var/lib/NetworkManager/* etc/NetworkManager/system-connections/*
var/lib/tailscale var/lib/waydroid var/lib/fprint/* var/lib/boltd/* var/lib/colord/*
var/lib/snapd/cache/* var/lib/hp-os/update/* var/lib/hp-os/factory-reset-request var/lib/hp-os/first-boot.qml
etc/hp-os/update etc/passwd- etc/shadow- etc/group- etc/gshadow- etc/subuid- etc/subgid-
etc/sudoers.d/simon-packages etc/sudoers.d/hpos-panel-brightness
usr/local/bin/n1x-simon-* usr/local/bin/pi-apps etc/ssh/ssh_host_*
usr/share/sddm/faces/[!r.]*.face.icon opt/hp-os/niri-patch/session-hpos/*.bak-*
""".split()
LOOKED_AT = ("etc", "opt", "usr/local", "usr/share/sddm", "usr/share/applications", "var/lib/hp-os", "var/lib/AccountsService",
             "var/lib/sddm", "boot/grub")
PERSONAL = re.compile(rb"/home/simon\b|simon3chong|simon-daytona|\bsimon-chong\b")
SYSTEM_FIRST, SYSTEM_LAST = 1000, 59999


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)


def edit(path, change):
    if path.is_file():
        status = path.stat()
        path.write_text(change(path.read_text()))
        os.chmod(path, status.st_mode & 0o7777)
        os.chown(path, status.st_uid, status.st_gid)


def remove_accounts(root):
    people = [line.split(":")[0] for line in (root / "etc/passwd").read_text().splitlines()
              if line.count(":") >= 6 and line.split(":")[2].isdigit() and SYSTEM_FIRST <= int(line.split(":")[2]) <= SYSTEM_LAST]
    keep = lambda line: line.split(":")[0] not in people
    without = lambda text: "".join(line + "\n" for line in text.splitlines() if keep(line))
    for name in ("passwd", "shadow", "subuid", "subgid"):
        edit(root / "etc" / name, without)

    def groups(text):
        out = []
        for line in text.splitlines():
            fields = line.split(":")
            if fields[0] in people:
                continue
            fields[-1] = ",".join(member for member in fields[-1].split(",") if member and member not in people)
            out.append(":".join(fields))
        return "".join(line + "\n" for line in out)
    for name in ("group", "gshadow"):
        edit(root / "etc" / name, groups)
    return people


def set_identity(root):
    (root / "etc/hostname").write_text("hp-os\n")
    edit(root / "etc/hosts", lambda text: re.sub(r"simon-daytona", "hp-os", text))
    release = root / "usr/lib/os-release"
    edit(release, lambda text: re.sub(r'^PRETTY_NAME=.*$', 'PRETTY_NAME="HP-OS"', text, flags=re.M))
    edit(root / "etc/lsb-release", lambda text: re.sub(r'^DISTRIB_DESCRIPTION=.*$', 'DISTRIB_DESCRIPTION="HP-OS"', text, flags=re.M))
    for name in ("etc/issue", "etc/issue.net"):
        if (root / name).is_file():
            (root / name).write_text("HP-OS\n")
    edit(root / "etc/nix/nix.conf", lambda text: re.sub(r"(?<=[ =])(simon-chong|simon)(?= |$)", "", text, flags=re.M))


def clean_snaps(root):
    """Snap's own record of who was signed in on this laptop."""
    state = root / "var/lib/snapd/state.json"
    if not state.is_file():
        return
    document = json.loads(state.read_text())
    data = document.get("data", {})
    for key in ("auth", "device"):
        data.pop(key, None)
    edit(state, lambda _: json.dumps(document))


def personal_files(root):
    found = []
    for base in LOOKED_AT:
        for folder, directories, files in os.walk(root / base):
            for name in files:
                path = Path(folder, name)
                try:
                    if path.is_symlink():
                        if PERSONAL.search(os.fsencode(os.readlink(path))):
                            found.append(str(path.relative_to(root)))
                    elif path.is_file() and path.stat().st_size < 4_000_000 and PERSONAL.search(path.read_bytes()):
                        found.append(str(path.relative_to(root)))
                except OSError:
                    pass
    return sorted(found)


def prepare(root):
    root = Path(root)
    people = remove_accounts(root)
    for pattern in ERASED:
        for path in glob.glob(str(root / pattern)):
            remove(path)
    set_identity(root)
    clean_snaps(root)
    (root / "etc/hp-os").mkdir(parents=True, exist_ok=True)
    (root / "etc/hp-os/standard-device").write_text("Made with the HP-OS USB installer.\n")
    for folder in ("home", "root", "tmp", "var/tmp", "var/log"):
        (root / folder).mkdir(parents=True, exist_ok=True)
    os.chmod(root / "root", 0o700)
    os.chmod(root / "tmp", 0o1777)
    os.chmod(root / "var/tmp", 0o1777)
    return people, personal_files(root)


if __name__ == "__main__":
    removed, leftovers = prepare(sys.argv[1])
    print("Removed accounts: %s" % (", ".join(removed) or "none"))
    if leftovers:
        print("Personal details were found in these files, so the USB stick was not finished:")
        print("\n".join("  " + item for item in leftovers))
        sys.exit(1)
