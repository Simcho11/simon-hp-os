#!/usr/bin/python3
"""Creates one standard HP-OS account. Run through pkexec, so an administrator has already approved.

Reads one JSON line {"name", "username", "password", "picture"} from stdin and answers with one JSON
line. "picture" is empty (their initial) or the name of one of the pictures shipped beside this file.
It can only ever create a standard (non-administrator) account, and never touches an existing one.

With --first-boot it is started by the hp-os-first-setup socket instead, for the login screen of a device
that has never been set up: it makes the device's first account, an administrator. It refuses unless the
device is marked as new and has no administrator yet.
"""
import ctypes
import fcntl
import grp
import json
import os
import pwd
import re
import secrets
import socket
import struct
import subprocess
import sys
import threading

from gi.repository import Gio, GLib

SERVICE = "org.freedesktop.Accounts"
ROOT = "/org/freedesktop/Accounts"
USER = SERVICE + ".User"
SESSION = "/opt/hp-os/login/sessions/hpos.desktop"
PICTURES = ("daybreak", "tide", "bloom", "dune", "aurora")
FACES = "/usr/share/sddm/faces"
SETUP = "/nix/var/nix/profiles/hp-os-accounts/bin/hp-os-account-setup"
SETUP_LIMIT_SECONDS = 1800
FIRST_BOOT = "/var/lib/hp-os/first-boot.qml"
ADMIN_GROUPS = ("sudo", "admin", "wheel")


class Refused(Exception):
    """A reason the person can act on."""


def call(bus, path, interface, method, signature=None, values=()):
    parameters = GLib.Variant(signature, values) if signature else None
    return bus.call_sync(SERVICE, path, interface, method, parameters, None,
                         Gio.DBusCallFlags.NONE, 120000, None).unpack()


def password_hash(password):
    library = ctypes.CDLL("libcrypt.so.1")
    library.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    library.crypt.restype = ctypes.c_char_p
    result = library.crypt(password.encode(), ("$6$" + secrets.token_hex(8) + "$").encode())
    if not result or result.startswith(b"*"):
        raise RuntimeError("password encoding failed")
    return result.decode()


def validated(request):
    name = request.get("name")
    username = request.get("username")
    password = request.get("password")
    picture = request.get("picture", "")
    if picture != "" and picture not in PICTURES:
        raise Refused("That picture can’t be used.")
    if not isinstance(name, str) or not name.strip() or len(name) > 64 or re.search(r"[:,=\\\x00-\x1f\x7f]", name):
        raise Refused("Enter a name without special characters.")
    if not isinstance(username, str) or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        raise Refused("That username can’t be used.")
    if not isinstance(password, str) or not 8 <= len(password) <= 256 or "\0" in password:
        raise Refused("Use a password of at least 8 characters.")
    try:
        pwd.getpwnam(username)
    except KeyError:
        return name.strip(), username, password, picture
    raise Refused("That username is already in use.")


def remove_login_picture(username):
    try:
        os.unlink(os.path.join(FACES, username + ".face.icon"))
    except FileNotFoundError:
        pass


def set_picture(bus, path, picture):
    """AccountsService keeps the picture; the login screen, desktop and Settings all read it from there.
    Empty clears anything left by an earlier account of the same name."""
    source = os.path.join(os.path.dirname(os.path.realpath(__file__)), "pictures", picture + ".jpg") if picture else ""
    call(bus, path, USER, "SetIconFile", "(s)", (source,))


def allow_airdrop(username):
    """AirDrop's radio is limited to this group. Devices without AirDrop don't have it."""
    try:
        grp.getgrnam("omdrop")
    except KeyError:
        return
    subprocess.run(["/usr/sbin/usermod", "-aG", "omdrop", username], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def create(name, username, password, picture, administrator=False):
    if not os.path.isfile(SESSION):
        raise Refused("HP-OS isn’t fully installed on this device.")
    encoded = password_hash(password)
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    remove_login_picture(username)  # Left by an earlier account of the same name.
    path = call(bus, ROOT, SERVICE, "CreateUser", "(ssi)", (username, name, 1 if administrator else 0))[0]
    try:
        # Stays locked until everything else has succeeded.
        call(bus, path, USER, "SetLocked", "(b)", (True,))
        call(bus, path, USER, "SetXSession", "(s)", ("hpos",))
        account = pwd.getpwnam(username)
        # Only the new account's real home; never follow a substituted symlink.
        fd = os.open(account.pw_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_uid != account.pw_uid:
                raise RuntimeError("unexpected home ownership")
            os.fchmod(fd, 0o700)
        finally:
            os.close(fd)
        allow_airdrop(username)
        set_picture(bus, path, picture)
        call(bus, path, USER, "SetPassword", "(ss)", (encoded, ""))
        call(bus, path, USER, "SetLocked", "(b)", (False,))
    except Exception:
        # Never leave a half-made account behind.
        remove_login_picture(username)
        uid = pwd.getpwnam(username).pw_uid
        call(bus, ROOT, SERVICE, "DeleteUser", "(xb)", (uid, True))
        raise


def say(message):
    try:
        print(json.dumps(message), flush=True)
    except OSError:
        pass  # The window closed; the desktop still gets finished.


def prepare(username):
    """Sets up the new person's desktop now, as them, so their first sign-in is quick.
    If this fails the account is still fine: the first sign-in finishes the job."""
    try:
        account = pwd.getpwnam(username)
        environment = {"HOME": account.pw_dir, "USER": username, "LOGNAME": username,
                       "PATH": "/usr/bin:/bin", "HP_OS_SETUP_PROGRESS": "1"}
        child = subprocess.Popen([SETUP], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, cwd=account.pw_dir, env=environment,
                                 user=account.pw_uid, group=account.pw_gid, umask=0o022,
                                 extra_groups=os.getgrouplist(username, account.pw_gid))
        limit = threading.Timer(SETUP_LIMIT_SECONDS, child.kill)
        limit.start()
        for line in child.stdout:
            found = re.fullmatch(r"HP-OS-PROGRESS (\d{1,3})\n?", line)
            if found:
                say({"progress": min(100, int(found.group(1)))})
        limit.cancel()
        return child.wait() == 0
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        return False


def new_device():
    """Only a device marked as new, with no administrator yet, and only its login screen may use first-time setup."""
    peer = socket.socket(fileno=os.dup(0))
    uid = struct.unpack("3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
    peer.close()
    if uid != pwd.getpwnam("sddm").pw_uid or not os.path.isfile(FIRST_BOOT):
        raise Refused("This device is already set up.")
    for account in pwd.getpwall():
        if 1000 <= account.pw_uid < 60000:
            groups = {grp.getgrgid(gid).gr_name for gid in os.getgrouplist(account.pw_name, account.pw_gid)}
            if groups & set(ADMIN_GROUPS):
                raise Refused("This device is already set up.")


def main(first_boot=False):
    try:
        request = validated(json.loads(sys.stdin.readline()))
        if first_boot:
            lock = open("/run/hp-os/first-setup.lock", "w")
            fcntl.flock(lock, fcntl.LOCK_EX)
            new_device()
        create(*request, administrator=first_boot)
        if first_boot:
            os.unlink(FIRST_BOOT)   # Set up: this screen never comes back.
        say({"progress": 1})
        return {"ok": True, "prepared": prepare(request[1])}
    except Refused as reason:
        return {"ok": False, "error": str(reason)}
    except (GLib.Error, OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError):
        return {"ok": False, "error": "The account couldn’t be created. Nothing was changed."}


if __name__ == "__main__":
    answer = main("--first-boot" in sys.argv)
    print(json.dumps(answer))
    sys.exit(0 if answer["ok"] else 1)
