#!/usr/bin/python3
"""Each account's wallpaper on the login screen.

  hp-os-login-wallpaper share    as a desktop user: send this account's wallpaper to the login screen
  hp-os-login-wallpaper serve    run as root by hp-os-login-wallpaper@.service (socket activated)

The login screen can't read home folders, so each account shares a copy of its wallpaper when it signs in and out:
the session converts it to a JPEG and sends the picture itself (never a path), and this service keeps it, readable by
the login screen, in /var/lib/hp-os/login-wallpapers/<account>.jpg. The device owner's (the first administrator's)
is also default.jpg, which the login screen shows until someone is picked.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile

SOCKET = "/run/hp-os/login-wallpaper.sock"
FOLDER = "var/lib/hp-os/login-wallpapers"
LIMIT = 12 * 1024 * 1024
NAME = re.compile(r"[a-z_][a-z0-9_-]{0,31}")


def device_tools(root):
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hp-os-device")
    if not os.path.exists(path):
        path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hp-os-device.py")
    loader = importlib.machinery.SourceFileLoader("hp_os_device", path)
    spec = importlib.util.spec_from_loader("hp_os_device", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module.Device(root)


def is_jpeg(data):
    return len(data) > 1024 and data[:3] == b"\xff\xd8\xff" and data.rstrip(b"\0")[-2:] == b"\xff\xd9"


def keep(root, uid, data):
    """Stores one account's picture. Returns the files written."""
    device = device_tools(root)
    who = device.person(uid)
    if not who or not NAME.fullmatch(who["name"]) or who["home"] != "/home/" + who["name"]:
        raise ValueError("Only a desktop account can share its wallpaper.")
    if not is_jpeg(data) or len(data) > LIMIT:
        raise ValueError("That isn't a picture the login screen can show.")
    folder = Path(root) / FOLDER
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o755)
    admins = sorted((other for other in device.people() if device.is_admin(other)), key=lambda other: other["uid"])
    names = [who["name"] + ".jpg"] + (["default.jpg"] if admins and admins[0]["uid"] == uid else [])
    for name in names:
        descriptor, temporary = tempfile.mkstemp(dir=folder, prefix=".new-")
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, folder / name)
    # Pictures of accounts that no longer exist go.
    living = {other["name"] + ".jpg" for other in device.people()} | {"default.jpg"}
    for leftover in folder.iterdir():
        if leftover.name not in living:
            leftover.unlink(missing_ok=True)
    return names


def serve(root="/"):
    connection = socket.socket(fileno=0)
    uid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
    stream = connection.makefile("rb")
    try:
        request = json.loads(stream.readline(512))
        size = int(request.get("bytes", 0))
        if request.get("action") != "share" or not 0 < size <= LIMIT:
            raise ValueError("That request isn't available.")
        data = stream.read(size)
        if len(data) != size:
            raise ValueError("The picture didn't arrive whole.")
        reply = {"ok": True, "kept": keep(root, uid, data)}
    except (ValueError, OSError) as error:
        reply = {"ok": False, "error": str(error)}
    connection.sendall((json.dumps(reply) + "\n").encode())


def share():
    """Runs in the desktop session, as its account."""
    home = Path.home()
    try:
        settings = json.loads((home / ".config/hp-os/config.json").read_text())
        picture = Path(str(settings["background"]["wallpaperPath"])).expanduser()
    except (OSError, ValueError, KeyError, TypeError):
        return "no wallpaper set"
    if not picture.is_file():
        return "wallpaper not found"
    stamp = home / ".cache/hp-os/login-wallpaper"
    marker = "%s %d %d\n" % (picture, picture.stat().st_mtime_ns, picture.stat().st_size)
    if stamp.is_file() and stamp.read_text() == marker:
        return "already shared"
    magick = shutil.which("magick")
    if not magick:
        return "no image tool"
    converted = subprocess.run([magick, str(picture) + "[0]", "-auto-orient", "-resize", "2880x1800^", "-strip",
                                "-quality", "85", "jpg:-"], capture_output=True, timeout=90, check=False)
    if converted.returncode != 0 or not is_jpeg(converted.stdout):
        return "conversion failed"
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(30)
        connection.connect(SOCKET)
        connection.sendall(json.dumps({"action": "share", "bytes": len(converted.stdout)}).encode() + b"\n")
        connection.sendall(converted.stdout)
        answer = json.loads(connection.makefile("r").readline() or "{}")
    if answer.get("ok"):
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(marker)
        return "shared"
    return answer.get("error", "not shared")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "serve":
        serve()
    elif command == "share":
        print(share())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
