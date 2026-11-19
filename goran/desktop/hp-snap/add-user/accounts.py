#!/usr/bin/python3
"""Creates one standard HP-OS account. Run through pkexec, so an administrator has already approved.

Reads one JSON line {"name", "username", "password", "picture"} from stdin and answers with one JSON
line. "picture" is empty (their initial) or the name of one of the pictures shipped beside this file.
It can only ever create a standard (non-administrator) account, and never touches an existing one.

With --first-boot it is started by the hp-os-first-setup socket instead, for the login screen of a device
that has never been set up: it makes the device's first account, an administrator. It refuses unless the
device is marked as new and has no administrator yet. On such a device it also answers the welcome's Wi-Fi and
Software Update steps, and the time zone step after the password: {"action": "wifi-list" | "wifi-join" |
"update-check" | "update-install" | "update-status" | "restart" | "timezone-list" | "timezone-set" |
"recovery-key" | "wifi-connectivity"}. The recovery key itself is made and kept by /opt/hp-os/device/hp-os-recovery.
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
NMCLI = "/usr/bin/nmcli"
CONNECTIONS = "/etc/NetworkManager/system-connections"
UPDATE_STATE = "/var/lib/hp-os/update"
RECOVERY = "/opt/hp-os/device/hp-os-recovery"
# Left for the welcome by the restart that finishes an update, so it carries on at the name step.
UPDATED_MARK = "/var/lib/hp-os/welcome-updated.qml"
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


# ── The welcome's Wi-Fi and Software Update steps (a new device only) ──
def run(*command, timeout=60):
    return subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, check=False)


def online():
    state = run(NMCLI, "-t", "-f", "CONNECTIVITY", "general", timeout=15).stdout.strip()
    return state == "full"


# A network that wants a web sign-in first (hotels, cafés, airports) answers this plain-HTTP address with its own page
# or a redirect instead of the empty 204.
PROBE = "http://connectivity-check.ubuntu.com/"


def connectivity():
    """("full" | "portal" | "limited" | "none" | "unknown", the page to open for a sign-in). NetworkManager's own check
    first, asked to look again now; a direct look at PROBE when it can't tell (a device without its check set up)."""
    try:
        state = run(NMCLI, "networking", "connectivity", "check", timeout=25).stdout.strip()
    except subprocess.SubprocessError:
        state = "unknown"
    if state in ("full", "portal") and state:
        return state, PROBE
    try:
        answer = run("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", "--max-time", "8",
                     PROBE, timeout=15).stdout.split()
    except subprocess.SubprocessError:
        answer = []
    code = answer[0] if answer else "000"
    if code == "204":
        return "full", PROBE
    if code[:1] in ("2", "3"):
        page = answer[1] if len(answer) > 1 and re.fullmatch(r"https?://[^\s]{1,2000}", answer[1]) else PROBE
        return "portal", page
    return state or "none", PROBE


def split_fields(line):
    """nmcli -t separates fields with ':' and escapes ':' and '\\' inside them."""
    fields, current, escaped = [], "", False
    for char in line:
        if escaped:
            current += char
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append(current)
            current = ""
        else:
            current += char
    return fields + [current]


def wifi_list():
    listed = run(NMCLI, "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes", timeout=40)
    best = {}
    for line in listed.stdout.splitlines():
        fields = split_fields(line)
        if len(fields) < 4 or not fields[1].strip():
            continue
        name, security = fields[1], fields[3].strip()
        network = {"ssid": name, "signal": int(fields[2]) if fields[2].isdigit() else 0, "connected": fields[0] == "*",
                   "secure": security not in ("", "--"), "wep": "WEP" in security, "sae": security == "WPA3"}
        if name not in best or network["signal"] > best[name]["signal"]:
            best[name] = network
    networks = sorted(best.values(), key=lambda network: (not network["connected"], -network["signal"]))[:30]
    state, page = connectivity() if any(network["connected"] for network in networks) else ("none", PROBE)
    return {"ok": True, "online": state == "full" or online(), "connectivity": state, "signIn": page, "networks": networks}


def keyfile_value(text):
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def wifi_join(request):
    import uuid
    ssid, password = request.get("ssid"), request.get("password", "")
    if not isinstance(ssid, str) or not 0 < len(ssid.encode()) <= 32 or re.search(r"[\x00-\x1f\x7f]", ssid):
        raise Refused("Choose a network from the list.")
    secure = bool(request.get("secure"))
    if secure and (not isinstance(password, str) or not re.fullmatch(r"[\x20-\x7e]{8,63}|[0-9A-Fa-f]{64}", password)):
        raise Refused("A Wi-Fi password has 8 to 63 characters.")
    identifier = str(uuid.uuid4())
    lines = ["[connection]", "id=" + keyfile_value(ssid), "uuid=" + identifier, "type=wifi", "autoconnect=true", "",
             "[wifi]", "mode=infrastructure", "ssid=" + ";".join(str(byte) for byte in ssid.encode()) + ";", ""]
    if secure:
        lines += ["[wifi-security]", "key-mgmt=" + ("sae" if request.get("sae") else "wpa-psk"),
                  "psk=" + keyfile_value(password), ""]
    lines += ["[ipv4]", "method=auto", "", "[ipv6]", "method=auto", ""]
    path = os.path.join(CONNECTIONS, "hp-os-wifi-%s.nmconnection" % identifier)
    # The password goes straight into NetworkManager's private folder, never onto a command line.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write("\n".join(lines))
    run(NMCLI, "connection", "reload", timeout=20)
    joined = run(NMCLI, "--wait", "40", "connection", "up", "uuid", identifier, timeout=60)
    if joined.returncode != 0:
        run(NMCLI, "connection", "delete", "uuid", identifier, timeout=20)
        if os.path.exists(path):
            os.unlink(path)
            run(NMCLI, "connection", "reload", timeout=20)
        raise Refused("Couldn’t join %s. Check the password and try again." % ssid)
    state, page = connectivity()
    return {"ok": True, "online": state == "full", "connectivity": state, "signIn": page}


def update_status():
    try:
        with open(os.path.join(UPDATE_STATE, "status.json")) as stream:
            status = json.load(stream)
    except (OSError, ValueError):
        status = {}
    keep = ("state", "installed", "available", "progress", "message", "checkError")
    return {"ok": True, "status": {key: status.get(key) for key in keep if key in status}}


def update_check():
    # The check also works out the update's size and download time, which can take a few minutes on a slow device.
    run("/usr/bin/systemctl", "start", "hp-os-update-check.service", timeout=1500)
    return update_status()


def update_install():
    if (update_status()["status"].get("state") or "idle") in ("downloading", "installing", "restoring"):
        return {"ok": True}
    with open(os.path.join(UPDATE_STATE, "job"), "w") as stream:
        stream.write("install\n")
    run("/usr/bin/systemctl", "start", "--no-block", "hp-os-update-job.service", timeout=30)
    return {"ok": True}


ZONEINFO = "/usr/share/zoneinfo"
# What people call the places they search for: time names, states, big cities without their own time zone.
# A zone listed here is also a common choice, shown ahead of small places that match as well.
ZONE_NAMES = {
    "America/Los_Angeles": "Pacific Time PT West Coast California San Francisco SF LA Seattle Washington State Portland Oregon Las Vegas Nevada San Diego San Jose USA US America",
    "America/Vancouver": "Pacific Time PT British Columbia BC",
    "America/Tijuana": "Pacific Time PT Baja California",
    "America/Denver": "Mountain Time MT Colorado Utah Salt Lake City Albuquerque New Mexico Boise Idaho Montana Wyoming USA US America",
    "America/Phoenix": "Mountain Time MT Arizona Tucson USA US America",
    "America/Edmonton": "Mountain Time MT Alberta Calgary",
    "America/Chicago": "Central Time CT Illinois Texas Dallas Houston Austin San Antonio Minnesota Minneapolis Missouri St Louis Kansas City New Orleans Louisiana Nashville Tennessee Wisconsin Milwaukee Iowa Oklahoma USA US America",
    "America/Winnipeg": "Central Time CT Manitoba",
    "America/Mexico_City": "Central Time Mexico Guadalajara Monterrey",
    "America/New_York": "Eastern Time ET East Coast New York City NYC Boston Massachusetts Washington DC Philadelphia Pennsylvania Pittsburgh Atlanta Georgia Miami Orlando Florida Charlotte North Carolina Virginia Baltimore Maryland Ohio Cleveland Columbus New Jersey Connecticut USA US America",
    "America/Detroit": "Eastern Time ET Michigan",
    "America/Toronto": "Eastern Time ET Ontario Ottawa Montreal Quebec",
    "America/Halifax": "Atlantic Time AT Nova Scotia",
    "America/St_Johns": "Newfoundland Time",
    "America/Anchorage": "Alaska Time AKT",
    "Pacific/Honolulu": "Hawaii Time HT",
    "America/Sao_Paulo": "Brazil Rio de Janeiro Brasilia",
    "America/Argentina/Buenos_Aires": "Argentina",
    "America/Bogota": "Colombia", "America/Lima": "Peru", "America/Santiago": "Chile",
    "Europe/London": "UK United Kingdom Britain Great Britain England Scotland Wales Northern Ireland Manchester Edinburgh",
    "Europe/Dublin": "Ireland Irish Time",
    "Europe/Lisbon": "Portugal",
    "Europe/Paris": "France Europe European", "Europe/Berlin": "Germany Europe European Munich Frankfurt Hamburg",
    "Europe/Madrid": "Spain Barcelona Europe European", "Europe/Rome": "Italy Milan Europe European",
    "Europe/Amsterdam": "Netherlands Holland Europe European", "Europe/Brussels": "Belgium Europe European",
    "Europe/Zurich": "Switzerland Geneva Europe European", "Europe/Stockholm": "Sweden Europe European",
    "Europe/Warsaw": "Poland Europe European", "Europe/Vienna": "Austria Europe European",
    "Europe/Athens": "Greece Eastern European Time", "Europe/Kyiv": "Ukraine Kiev Eastern European Time",
    "Europe/Istanbul": "Turkey Türkiye", "Europe/Moscow": "Russia Moscow Time",
    "Africa/Cairo": "Egypt", "Africa/Lagos": "Nigeria West Africa Time", "Africa/Nairobi": "Kenya East Africa Time",
    "Africa/Johannesburg": "South Africa Cape Town", "Asia/Dubai": "UAE United Arab Emirates Gulf Abu Dhabi",
    "Asia/Jerusalem": "Israel Tel Aviv", "Asia/Riyadh": "Saudi Arabia",
    "Asia/Karachi": "Pakistan Lahore Islamabad", "Asia/Kolkata": "India Indian Time Delhi New Delhi Mumbai Bombay Bangalore Bengaluru Chennai Hyderabad Pune Calcutta",
    "Asia/Kathmandu": "Nepal", "Asia/Dhaka": "Bangladesh", "Asia/Bangkok": "Thailand", "Asia/Jakarta": "Indonesia",
    "Asia/Ho_Chi_Minh": "Vietnam Saigon Hanoi", "Asia/Singapore": "Singapore", "Asia/Kuala_Lumpur": "Malaysia",
    "Asia/Manila": "Philippines", "Asia/Shanghai": "China Beijing Shenzhen Guangzhou China Time", "Asia/Hong_Kong": "Hong Kong",
    "Asia/Taipei": "Taiwan", "Asia/Seoul": "South Korea Korea", "Asia/Tokyo": "Japan Osaka",
    "Australia/Sydney": "Australia New South Wales NSW Canberra Australian Eastern Time",
    "Australia/Melbourne": "Australia Victoria Australian Eastern Time", "Australia/Brisbane": "Australia Queensland",
    "Australia/Perth": "Australia Western Australia", "Australia/Adelaide": "Australia South Australia",
    "Pacific/Auckland": "New Zealand NZ Wellington",
}

# The very most chosen: ahead of other common places that match a search equally well (PST: Los Angeles first).
MAJOR_ZONES = {"America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
               "Europe/London", "Europe/Paris", "Europe/Berlin", "Asia/Kolkata", "Asia/Shanghai", "Asia/Tokyo",
               "America/Sao_Paulo", "America/Mexico_City", "Asia/Dubai", "Asia/Singapore"}


def time_zones():
    """Every place in the system's own time zone list, by country, with its distance from GMT today, its time names
    (PST, PDT, CET…) and what else people call it."""
    import datetime
    import zoneinfo
    countries = {}
    with open(os.path.join(ZONEINFO, "iso3166.tab"), encoding="utf-8") as stream:
        for line in stream:
            if line.strip() and not line.startswith("#"):
                code, _, name = line.rstrip("\n").partition("\t")
                countries[code] = name
    now = datetime.datetime.now(datetime.timezone.utc)
    seasons = [datetime.datetime(now.year, month, 15, 12, tzinfo=datetime.timezone.utc) for month in (1, 7)]
    zones = []
    with open(os.path.join(ZONEINFO, "zone.tab"), encoding="utf-8") as stream:
        for line in stream:
            fields = line.rstrip("\n").split("\t")
            if line.startswith("#") or len(fields) < 3:
                continue
            try:
                place = zoneinfo.ZoneInfo(fields[2])
                offset = int(now.astimezone(place).utcoffset().total_seconds() // 60)
                # Real names only, not "+05".
                names = sorted({moment.astimezone(place).tzname() for moment in seasons + [now]} - {None})
            except (zoneinfo.ZoneInfoNotFoundError, ValueError):
                continue
            zones.append({"zone": fields[2], "country": countries.get(fields[0], fields[0]),
                          "city": fields[2].rsplit("/", 1)[-1].replace("_", " "),
                          "region": fields[3] if len(fields) > 3 else "", "offset": offset,
                          "abbr": [name for name in names if name.isalpha()],
                          "names": ZONE_NAMES.get(fields[2], ""),
                          "common": 2 if fields[2] in MAJOR_ZONES else 1 if fields[2] in ZONE_NAMES else 0})
    return sorted(zones, key=lambda zone: (zone["country"], zone["city"]))


def current_zone():
    try:
        return os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[1]
    except (OSError, IndexError):
        return ""


def set_time_zone(request):
    zone = request.get("zone")
    if not isinstance(zone, str) or zone not in {place["zone"] for place in time_zones()}:
        raise Refused("Choose a time zone from the list.")
    if run("/usr/bin/timedatectl", "set-timezone", zone, timeout=30).returncode != 0:
        raise Refused("The time zone couldn’t be set. You can try again.")
    return {"ok": True}


def recovery_key():
    """The new device's recovery key, shown once after the password step. Making it again replaces it."""
    if not os.path.isfile(RECOVERY):
        return {"ok": False, "error": "unavailable"}
    made = run("/usr/bin/python3", "-I", RECOVERY, "new", timeout=60)
    try:
        answer = json.loads(made.stdout)
    except ValueError:
        answer = {}
    if made.returncode != 0 or not isinstance(answer.get("key"), str):
        return {"ok": False, "error": "The recovery key couldn’t be made."}
    return {"ok": True, "key": answer["key"]}


def welcome_step(request):
    action = request.get("action")
    if action == "recovery-key":
        return recovery_key()
    if action == "wifi-connectivity":
        state, page = connectivity()
        return {"ok": True, "connectivity": state, "signIn": page}
    if action == "timezone-list":
        # A device with nothing that sets its clock (the first Intel laptops) gets it from the internet first, so the
        # times shown beside each place are right.
        updater = "/opt/hp-os/device/hp-os-update"
        if os.path.isfile(updater):
            try:
                run("/usr/bin/python3", "-I", updater, "clock", timeout=40)
            except subprocess.SubprocessError:
                pass
        return {"ok": True, "zones": time_zones(), "current": current_zone()}
    if action == "timezone-set":
        return set_time_zone(request)
    if action == "wifi-list":
        return wifi_list()
    if action == "wifi-join":
        return wifi_join(request)
    if action == "update-check":
        return update_check()
    if action == "update-install":
        return update_install()
    if action == "update-status":
        return update_status()
    if action == "restart":
        if (update_status()["status"].get("state") or "") == "restart":
            descriptor = os.open(UPDATED_MARK, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            with os.fdopen(descriptor, "w") as stream:
                stream.write("import QtQuick\nItem {}\n")
            os.chmod(UPDATED_MARK, 0o644)
        threading.Timer(1.5, lambda: run("/usr/bin/systemctl", "reboot", timeout=30)).start()
        return {"ok": True}
    raise Refused("That request isn’t available.")


def main(first_boot=False):
    try:
        request = json.loads(sys.stdin.readline())
        if first_boot and isinstance(request, dict) and "action" in request:
            new_device()
            return welcome_step(request)
        request = validated(request)
        if first_boot:
            lock = open("/run/hp-os/first-setup.lock", "w")
            fcntl.flock(lock, fcntl.LOCK_EX)
            new_device()
        create(*request, administrator=first_boot)
        if first_boot:
            os.unlink(FIRST_BOOT)   # Set up: this screen never comes back.
            if os.path.exists(UPDATED_MARK):
                os.unlink(UPDATED_MARK)
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
