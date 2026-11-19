#!/usr/bin/python3
"""HP-OS recovery key: lets the owner set a new password after forgetting theirs, without losing any files.

  hp-os-recovery new       make this device's recovery key (root only; first-time setup asks for it), print it
  hp-os-recovery request   answer one request from /run/hp-os/recovery.sock (socket activated)
  hp-os-recovery status    print whether this device has a recovery key

Requests, one JSON line each:
  {"action": "status"}                                  does this device have a key?
  {"action": "new", "password": P}                      an administrator makes a new key (the old one stops working)
  {"action": "save-usb", "key": K}                      copy the key, as a small text file, to a USB stick
  {"action": "reset", "user": U, "key": K, "password": P}
                                                        the login screen sets a new password for U

The key is 24 letters and digits (about 120 bits), shown once. The device keeps only a salted scrypt hash of it,
private to root. Wrong keys are slowed down, then locked out for a while. Nothing here runs in the background.
"""
import ctypes
import datetime
import grp
import hashlib
import hmac
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time

ADMIN_GROUPS = ("sudo", "admin", "wheel")
# No I, O, 0 or 1, which are easy to mix up when copying by hand.
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
KEY_LENGTH = 24
MARK = "import QtQuick\nItem {}\n"        # Lets the login screen see that a key exists, with no privileges.
SCRYPT = {"n": 2 ** 15, "r": 8, "p": 1}
FREE_TRIES = 5
USB_FILESYSTEMS = ("vfat", "exfat", "ntfs", "ntfs3")


def private_write(path, text, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def normalized(key):
    """What the person typed, without spaces, dashes or lower case."""
    return re.sub(r"[^A-Z0-9]", "", str(key).upper())


def grouped(key):
    return "-".join(key[i:i + 4] for i in range(0, len(key), 4))


class Recovery:
    def __init__(self, root="/", run=None, now=time.time, pause=time.sleep):
        self.root = Path(root)
        self.state = self.root / "var/lib/hp-os"
        self.keyfile = self.state / "recovery-key"
        self.mark = self.state / "recovery-key.qml"
        self.tries = self.state / "recovery-tries"
        self.now, self.pause = now, pause
        self.run = run or (lambda command, data=None: subprocess.run(
            command, input=data, capture_output=True, text=True, timeout=120, check=False))

    # ── The key ──
    def has_key(self):
        try:
            return isinstance(json.loads(self.keyfile.read_text()).get("hash"), str)
        except (OSError, ValueError, AttributeError):
            return False

    @staticmethod
    def digest(key, salt, settings):
        return hashlib.scrypt(normalized(key).encode(), salt=bytes.fromhex(salt), n=settings["n"], r=settings["r"],
                              p=settings["p"], maxmem=128 * 1024 * 1024, dklen=32).hex()

    def new(self):
        key = "".join(secrets.choice(ALPHABET) for _ in range(KEY_LENGTH))
        salt = secrets.token_hex(16)
        record = dict(SCRYPT, salt=salt, hash=self.digest(key, salt, SCRYPT), made=int(self.now()))
        private_write(self.keyfile, json.dumps(record) + "\n", 0o600)
        private_write(self.mark, MARK, 0o644)
        self.forget_tries()
        return {"ok": True, "key": grouped(key)}

    def matches(self, key):
        try:
            record = json.loads(self.keyfile.read_text())
            status = os.lstat(self.keyfile)
        except (OSError, ValueError):
            return False
        if status.st_uid != os.getuid() or status.st_mode & 0o077 or len(normalized(key)) != KEY_LENGTH:
            return False
        settings = {name: int(record.get(name, 0)) for name in SCRYPT}
        if not all(settings.values()) or settings["n"] > 2 ** 20:
            return False
        return hmac.compare_digest(self.digest(key, record["salt"], settings), str(record.get("hash")))

    # ── Wrong keys: five free tries, then a wait that doubles each time (1, 2, 4… minutes, at most a day) ──
    def read_tries(self):
        try:
            tries = json.loads(self.tries.read_text())
            return int(tries.get("failed", 0)), float(tries.get("until", 0))
        except (OSError, ValueError, AttributeError):
            return 0, 0.0

    def forget_tries(self):
        try:
            os.unlink(self.tries)
        except FileNotFoundError:
            pass

    def wait_left(self):
        return max(0, int(self.read_tries()[1] - self.now() + 0.999))

    def failed(self):
        count, _ = self.read_tries()
        count += 1
        until = self.now() + (min(86400, 60 * 2 ** (count - FREE_TRIES - 1)) if count > FREE_TRIES else 0)
        private_write(self.tries, json.dumps({"failed": count, "until": until}) + "\n", 0o600)
        self.pause(2)

    @staticmethod
    def wait_text(seconds):
        minutes = (seconds + 59) // 60
        return "Too many tries. Try again in %s." % ("1 minute" if minutes <= 1 else
                                                     "%d minutes" % minutes if minutes < 90 else
                                                     "%d hours" % round(minutes / 60))

    # ── People ──
    @staticmethod
    def person(name):
        """A person's account (never a system one)."""
        try:
            who = pwd.getpwnam(name)
        except (KeyError, ValueError):
            return None
        return who if 1000 <= who.pw_uid < 60000 else None

    def uid_person(self, uid):
        try:
            who = pwd.getpwuid(uid)
        except KeyError:
            return None
        return who if 1000 <= who.pw_uid < 60000 else None

    @staticmethod
    def is_admin(who):
        groups = {grp.getgrgid(gid).gr_name for gid in os.getgrouplist(who.pw_name, who.pw_gid)}
        return bool(groups & set(ADMIN_GROUPS))

    def shadow(self, name):
        for line in (self.root / "etc/shadow").read_text(errors="replace").splitlines():
            fields = line.split(":")
            if fields[0] == name and len(fields) > 1:
                return fields[1]
        return ""

    @staticmethod
    def crypt(password, setting):
        library = ctypes.CDLL("libcrypt.so.1")
        library.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        library.crypt.restype = ctypes.c_char_p
        result = library.crypt(password.encode(), setting.encode())
        if not result or result.startswith(b"*"):
            raise RuntimeError("password encoding failed")
        return result.decode()

    def password_matches(self, who, password):
        stored = self.shadow(who.pw_name)
        return bool(stored) and stored[0] not in "!*" and hmac.compare_digest(self.crypt(password, stored), stored)

    def set_password(self, who, password):
        encoded = self.crypt(password, "$6$" + secrets.token_hex(8) + "$")
        done = self.run(["/usr/sbin/chpasswd", "-e"], who.pw_name + ":" + encoded + "\n")
        if done.returncode != 0:
            raise RuntimeError("chpasswd failed")
        # Wrong passwords typed before the reset shouldn't keep the account locked.
        if os.path.exists(self.root / "usr/sbin/faillock"):
            self.run(["/usr/sbin/faillock", "--user", who.pw_name, "--reset"])

    # ── USB stick ──
    def usb_places(self):
        """Partitions on plugged-in USB sticks that a phone, Mac or PC can read too, best first."""
        listing = self.run(["/usr/bin/lsblk", "-J", "-p", "-o", "NAME,TYPE,TRAN,RM,HOTPLUG,FSTYPE,LABEL,MOUNTPOINTS,VENDOR,MODEL"])
        try:
            disks = json.loads(listing.stdout).get("blockdevices", [])
        except (ValueError, AttributeError):
            return []
        found = []
        for disk in disks:
            if disk.get("type") != "disk" or disk.get("tran") != "usb" or not (disk.get("rm") or disk.get("hotplug")):
                continue
            name = " ".join(str(disk.get(part) or "").strip() for part in ("vendor", "model")).strip() or "USB stick"
            for part in [disk] + list(disk.get("children") or []):
                if str(part.get("fstype") or "") in USB_FILESYSTEMS:
                    found.append({"device": part["name"], "label": str(part.get("label") or ""), "name": name,
                                  "mounted": [m for m in (part.get("mountpoints") or []) if m]})
        # Not the HP-OS installer stick if there's anything else.
        return sorted(found, key=lambda place: place["label"].startswith("HPOS-"))

    def save_usb(self, key):
        places = self.usb_places()
        if not places:
            return {"ok": False, "error": "Plug in a USB stick, then try again."}
        place = places[0]
        host = re.sub(r"[^A-Za-z0-9 ._-]", "", socket.gethostname()) or "this device"
        name = "HP-OS Recovery Key - %s.txt" % host
        today = datetime.date.fromtimestamp(self.now()).strftime("%-d %B %Y")
        text = ("HP-OS recovery key for %s\r\n\r\n    %s\r\n\r\nMade on %s.\r\n\r\n"
                "Forgot your password? On the login screen, choose Forgot password? and type this key.\r\n"
                "Keep it private: anyone with this key can set a new password on that device.\r\n"
                % (host, grouped(normalized(key)), today))
        folder = place["mounted"][0] if place["mounted"] else None
        own = None
        try:
            if folder is None:
                own = tempfile.mkdtemp(prefix="hp-os-usb-", dir="/run")
                if self.run(["/usr/bin/mount", "-o", "nosuid,nodev,noexec", place["device"], own]).returncode != 0:
                    return {"ok": False, "error": "That USB stick couldn’t be opened. Try another one."}
                folder = own
            target = Path(folder) / name
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
                stream.write(text)
                stream.flush()
                os.fsync(stream.fileno())
        except OSError:
            return {"ok": False, "error": "The key couldn’t be saved on that USB stick. Try another one."}
        finally:
            if own:
                self.run(["/usr/bin/umount", own])
                try:
                    os.rmdir(own)
                except OSError:
                    pass
        self.run(["/usr/bin/sync"])
        return {"ok": True, "saved": place["name"], "file": name}

    # ── Requests ──
    def answer(self, uid, message):
        action = message.get("action")
        if action == "status":
            return {"ok": True, "set": self.has_key()}
        if action == "new":
            who = self.uid_person(uid)
            if not who or not self.is_admin(who):
                return {"ok": False, "error": "Only an administrator can make a new recovery key."}
            password = message.get("password")
            if not isinstance(password, str) or not password or "\0" in password:
                return {"ok": False, "error": "Enter your password."}
            if not self.password_matches(who, password):
                self.pause(2)
                return {"ok": False, "error": "That password isn’t correct."}
            return self.new()
        if action == "save-usb":
            key = message.get("key")
            if not isinstance(key, str) or not self.matches(key):
                return {"ok": False, "error": "That isn’t this device’s recovery key."}
            return self.save_usb(key)
        if action == "reset":
            try:
                login_screen = pwd.getpwnam("sddm").pw_uid
            except KeyError:
                login_screen = -1
            if uid not in (0, login_screen):
                return {"ok": False, "error": "Use Forgot password? on the login screen."}
            if not self.has_key():
                return {"ok": False, "error": "This device doesn’t have a recovery key. Ask an administrator to set a new password."}
            who = self.person(str(message.get("user", "")))
            password, key = message.get("password"), message.get("key")
            if not who:
                return {"ok": False, "error": "Choose your account first."}
            if not isinstance(password, str) or not 8 <= len(password) <= 256 or "\0" in password or "\n" in password:
                return {"ok": False, "error": "Use a password of at least 8 characters."}
            left = self.wait_left()
            if left:
                return {"ok": False, "error": self.wait_text(left)}
            if not isinstance(key, str) or not self.matches(key):
                self.failed()
                left = self.wait_left()
                return {"ok": False, "error": self.wait_text(left) if left else "That recovery key isn’t right. Check it and try again."}
            self.forget_tries()
            self.set_password(who, password)
            return {"ok": True}
        return {"ok": False, "error": "That request isn’t available."}


def serve(recovery):
    connection = socket.socket(fileno=0)
    uid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
    reader = connection.makefile("r", encoding="utf-8", errors="replace")
    try:
        message = json.loads(reader.readline(4096))
        reply = recovery.answer(uid, message if isinstance(message, dict) else {})
    except ValueError:
        reply = {"ok": False, "error": "That request isn’t available."}
    except (OSError, RuntimeError, subprocess.SubprocessError):
        reply = {"ok": False, "error": "Something went wrong. Nothing was changed."}
    connection.sendall((json.dumps(reply) + "\n").encode())
    connection.close()


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    recovery = Recovery()
    if command == "request":
        serve(recovery)
    elif command == "new":
        if os.getuid() != 0:
            sys.exit("Run as root.")
        print(json.dumps(recovery.new()))
    elif command == "status":
        print(json.dumps({"set": recovery.has_key()}))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
