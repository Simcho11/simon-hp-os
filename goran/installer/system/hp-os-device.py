#!/usr/bin/python3
"""HP-OS factory reset, run as root by the units hp-os-device-setup.sh installs.

  hp-os-device request   answer one person asking for a reset (socket activated)
  hp-os-device wipe      at startup, before the login screen: carry out a confirmed reset
  hp-os-device plan      print what a reset would erase, and change nothing

A reset can only be asked for by an administrator who types their password twice. It is carried out at the
next startup, while nobody is signed in. Only the people on this device and their data are erased: the
operating system and everything in /nix stay, so the device starts again at its first-time setup.
"""
import ctypes
import glob
import hmac
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import time

ADMIN_GROUPS = ("sudo", "admin", "wheel")
FIRST_BOOT_MARK = "import QtQuick\nItem {}\n"
# Per-device data outside the home folders. Nothing else is ever removed.
ERASED = (
    "var/lib/AccountsService/users/*",
    "var/lib/AccountsService/icons/*",
    "var/lib/sddm/.local/state/hp-os-add-user",
    "var/lib/sddm/state.conf",
    "var/lib/systemd/linger/*",
    "var/crash/*",
    "var/mail/*",
    "etc/NetworkManager/system-connections/*",
    "var/lib/bluetooth/*/[0-9A-F][0-9A-F]:*",
    "var/lib/hp-os/login-wallpapers/*",
    "var/lib/hp-os/welcome-updated.qml",
)


class Device:
    def __init__(self, root="/", run=None):
        self.root = Path(root)
        self.run = run or (lambda command: subprocess.run(command, check=False, stdin=subprocess.DEVNULL,
                                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        self.state = self.root / "var/lib/hp-os"
        self.request = self.state / "factory-reset-request"
        self.first_boot = self.state / "first-boot.qml"

    def lines(self, name):
        try:
            return (self.root / name).read_text(errors="replace").splitlines()
        except OSError:
            return []

    def people(self):
        found = []
        for line in self.lines("etc/passwd"):
            fields = line.split(":")
            if len(fields) >= 7 and fields[2].isdigit() and 1000 <= int(fields[2]) < 60000:
                found.append({"name": fields[0], "uid": int(fields[2]), "gid": fields[3], "home": fields[5]})
        return found

    def person(self, uid):
        return next((who for who in self.people() if who["uid"] == uid), None)

    def is_admin(self, who):
        for line in self.lines("etc/group"):
            fields = line.split(":")
            if len(fields) >= 4 and fields[0] in ADMIN_GROUPS:
                if who["name"] in fields[3].split(",") or fields[2] == who["gid"]:
                    return True
        return False

    def password_matches(self, who, password):
        stored = next((line.split(":")[1] for line in self.lines("etc/shadow")
                       if line.split(":")[0] == who["name"] and line.count(":") >= 1), "")
        if not stored or stored[0] in "!*":
            return False
        library = ctypes.CDLL("libcrypt.so.1")
        library.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        library.crypt.restype = ctypes.c_char_p
        result = library.crypt(password.encode(), stored.encode())
        return bool(result) and hmac.compare_digest(result, stored.encode())

    def machine_id(self):
        return "".join(self.lines("etc/machine-id")).strip()

    def write_private(self, path, text, mode):
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o755)
        temporary = path.with_name(path.name + ".new")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)

    def answer(self, uid, message, pause=time.sleep):
        """One request from the person with this uid. Returns the reply."""
        who = self.person(uid)
        admin = bool(who) and self.is_admin(who)
        if message.get("action") == "check":
            return {"ok": True, "admin": admin}
        if message.get("action") != "erase":
            return {"ok": False, "error": "That request isn’t available."}
        if not admin:
            return {"ok": False, "error": "Only an administrator can reset this device."}
        password, again = message.get("password"), message.get("again")
        if not isinstance(password, str) or not isinstance(again, str) or not password or "\0" in password:
            return {"ok": False, "error": "Enter your password in both fields."}
        if not hmac.compare_digest(password.encode(), again.encode()):
            return {"ok": False, "error": "Those passwords don’t match."}
        if not self.password_matches(who, password):
            pause(2)
            return {"ok": False, "error": "That password isn’t correct."}
        self.write_private(self.request, json.dumps({"machine": self.machine_id(), "by": who["name"],
                                                     "at": int(time.time())}) + "\n", 0o600)
        return {"ok": True, "restart": True}

    def confirmed(self):
        """Only a request made on this very device, written by root and private to root, counts."""
        try:
            status = os.lstat(self.request)
            request = json.loads(self.request.read_text())
        except (OSError, ValueError):
            return False
        return (status.st_uid == os.getuid() and (status.st_mode & 0o777) == 0o600 and os.path.isfile(self.request)
                and not os.path.islink(self.request) and isinstance(request, dict)
                and bool(self.machine_id()) and request.get("machine") == self.machine_id())

    def own_home(self, who):
        """The folder userdel may remove: exactly /home/<name>, and a real folder."""
        home = self.root / str(who["home"]).lstrip("/")
        return who["home"] == "/home/" + who["name"] and home.is_dir() and not home.is_symlink()

    def leftovers(self, who=None):
        found = []
        for pattern in ERASED:
            found += sorted(glob.glob(str(self.root / pattern)))
        for who in self.people():
            for base in ("nix/var/nix/profiles/per-user", "nix/var/nix/gcroots/per-user"):
                path = self.root / base / who["name"]
                if os.path.lexists(path):
                    found.append(str(path))
        return found

    def remove(self, path):
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                os.unlink(path)
            except OSError:
                pass

    def plan(self):
        return {"accounts": [who["name"] for who in self.people()],
                "home folders": [who["home"] for who in self.people() if self.own_home(who)],
                "other data": [path[len(str(self.root).rstrip("/")):] for path in self.leftovers()]}

    def wipe(self):
        if not os.path.lexists(self.request):
            return "nothing requested"
        if not self.confirmed():
            self.remove(self.request)
            return "ignored a request that wasn't valid"
        # First, so a reset interrupted at any point still ends at first-time setup, never at a dead login screen.
        self.write_private(self.first_boot, FIRST_BOOT_MARK, 0o644)
        extras = self.leftovers()
        for who in self.people():
            self.run(["/usr/bin/loginctl", "disable-linger", who["name"]])
            self.run(["/usr/bin/loginctl", "terminate-user", who["name"]])
            self.run(["/usr/bin/systemctl", "stop", "user@%d.service" % who["uid"]])
            self.run(["/usr/bin/pkill", "-KILL", "-u", str(who["uid"])])
            own = self.own_home(who)
            self.run(["/usr/sbin/userdel", "-f"] + (["-r"] if own else []) + [who["name"]])
            home = self.root / str(who["home"]).lstrip("/")
            if own and os.path.lexists(home):
                shutil.rmtree(home, ignore_errors=True)
        for path in extras + self.leftovers():
            self.remove(path)
        self.run(["/usr/bin/journalctl", "--rotate"])
        self.run(["/usr/bin/journalctl", "--vacuum-time=1s"])
        if self.people():
            return "some accounts remain; will try again at the next startup"
        self.remove(self.request)
        self.run(["/usr/bin/sync"])
        return "erased"


def serve(device):
    connection = socket.socket(fileno=0)
    uid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
    reader = connection.makefile("r", encoding="utf-8", errors="replace")
    try:
        message = json.loads(reader.readline(4096))
        reply = device.answer(uid, message if isinstance(message, dict) else {})
    except ValueError:
        reply = {"ok": False, "error": "That request isn’t available."}
    connection.sendall((json.dumps(reply) + "\n").encode())
    connection.close()
    if reply.get("restart"):
        time.sleep(3)   # Time for the window to say what is happening.
        subprocess.run(["/usr/bin/systemctl", "reboot"], check=False)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    device = Device()
    if command == "request":
        serve(device)
    elif command == "wipe":
        print(device.wipe())
    elif command == "plan":
        print(json.dumps(device.plan(), indent=2))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
