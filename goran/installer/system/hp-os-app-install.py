#!/usr/bin/env python3
"""HP-OS App Installer's system helper: installs an app someone downloaded as a .deb file, like a Mac's installer.

  hp-os-app-install request     one request from /run/hp-os/app-install.sock (started by its socket)
  hp-os-app-install job TOKEN   installs a package an administrator approved (started by the request)

The window never hands over a path: it opens the file itself and passes the open file, so this helper (root) never
reads a path someone else chose. The file is copied, then checked: its name, version, publisher and whether this
device can run it. Only an administrator's password installs it, and never anything that would remove, downgrade or
replace a part of HP-OS itself (apt is asked first, in a trial run). Nothing here runs in the background.

Nothing in a downloaded package is verified: its name, description and publisher are whatever its maker wrote. The
window says so, says where the file came from when the browser noted it, and warns when the package adds a software
source of its own (so its maker can send this laptop more software later) or replaces something already installed.
"""
import array
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse

STATE = Path("/var/lib/hp-os/app-install")
ICONS = Path("/var/lib/hp-os/app-install-icons")    # readable by everyone: the window shows the app's own icon
LIMIT = 4 * 1024 ** 3                               # the largest download it takes
KEEP_SECONDS = 24 * 3600                            # copies nobody installed are deleted after a day
APT_ENV = {"DEBIAN_FRONTEND": "noninteractive", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C.UTF-8"}
APT_OPTIONS = ["-o", "DPkg::Lock::Timeout=300", "-o", "Dpkg::Options::=--force-confdef",
               "-o", "Dpkg::Options::=--force-confold"]
# The parts of HP-OS a downloaded app must never replace: start-up, the kernel, sign-in, the package tools and the
# services the desktop is made of. (Essential and required packages are refused by their own fields.)
PROTECTED = re.compile(r"(linux-.*|systemd.*|libsystemd.*|udev|grub.*|shim.*|efibootmgr|initramfs-tools.*|sddm.*"
                       r"|libpam.*|login|passwd|sudo.*|polkitd|pkexec|dbus.*|apt|apt-utils|dpkg|libc6|libc-bin"
                       r"|nix-.*|network-manager.*|wpasupplicant|pipewire.*|wireplumber|accountsservice"
                       r"|xwayland|mesa-.*|libgl1-mesa-dri|firmware-.*|linux-firmware|nvidia-.*"
                       r"|python3|python3\.\d+|python3-minimal|libpython3.*|openssh-.*|ca-certificates|chrony"
                       r"|base-files|base-passwd|bash|coreutils|util-linux|mount|tzdata|locales)")
NAME = re.compile(r"[a-z0-9][a-z0-9+.-]{0,99}")
# A software source of the package's own, and the key its updates are signed with. Many apps' makers add one so their
# app keeps itself up to date; it also lets them send this laptop other software later. Warned about, never refused.
SOURCE_FOLDERS = ("/etc/apt/sources.list.d/", "/etc/apt/trusted.gpg.d/", "/etc/apt/keyrings/", "/usr/share/keyrings/",
                  "/etc/apt/preferences.d/")
SOURCE_FILES = ("/etc/apt/sources.list", "/etc/apt/trusted.gpg")
# The same, done by the package's own install scripts instead of as files (Chrome and VS Code work this way).
SOURCE_WORDS = re.compile(rb"sources\.list|trusted\.gpg|/keyrings/|apt-key|add-apt-repository")
# Chrome (and other browsers) note on a download the page it came from.
ORIGIN_ATTRIBUTE = "user.xdg.origin.url"
HOST = re.compile(r"[a-z0-9]([a-z0-9-]{0,62}\.)*[a-z0-9-]{1,63}")


def device_tools():
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hp-os-device")
    loader = importlib.machinery.SourceFileLoader("hp_os_device", path)
    spec = importlib.util.spec_from_loader("hp_os_device", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def plain(text, limit):
    """One line of a package's own text, safe to show: no control characters, not too long."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def size_text(kilobytes):
    megabytes = kilobytes / 1024
    return "%.1f GB" % (megabytes / 1024) if megabytes >= 1000 else "%d MB" % round(megabytes) if megabytes >= 1 \
        else "Under 1 MB"


class Installer:
    def __init__(self, state=STATE, icons=ICONS, run=subprocess.run):
        self.state, self.icons, self.run = Path(state), Path(icons), run

    # ── The package itself ──
    def fields(self, deb):
        names = ["Package", "Version", "Architecture", "Maintainer", "Description", "Installed-Size", "Essential",
                 "Priority", "Homepage", "Pre-Depends"]
        found = self.run(["dpkg-deb", "--field", str(deb)] + names, capture_output=True, text=True, timeout=60)
        if found.returncode != 0:
            return None
        values, current = {}, None
        for line in found.stdout.splitlines():
            match = re.match(r"([A-Za-z-]+):\s?(.*)", line)
            if match and not line.startswith(" "):
                current = match.group(1)
                values[current] = match.group(2)
            elif current == "Description" and "long" not in values:
                values["long"] = line.strip()          # the first line of the long description
        return values

    def architectures(self):
        native = self.run(["dpkg", "--print-architecture"], capture_output=True, text=True).stdout.strip()
        foreign = self.run(["dpkg", "--print-foreign-architectures"], capture_output=True, text=True).stdout.split()
        return [native] + foreign

    def installed_version(self, package):
        found = self.run(["dpkg-query", "-W", "-f=${Status}\t${Version}", package], capture_output=True, text=True)
        status, _, version = found.stdout.partition("\t")
        return version.strip() if found.returncode == 0 and status.strip() == "install ok installed" else ""

    def newer(self, first, second):
        return self.run(["dpkg", "--compare-versions", first, "gt", second]).returncode == 0

    def members(self, deb, wanted, seen=None, part="--fsys-tarfile"):
        """{path: bytes} of the package's small regular files for which wanted(path) is true, read as a stream.
        seen(path), when given, is told every path on the way. part="--ctrl-tarfile" reads its install scripts."""
        import tarfile
        found = {}
        process = subprocess.Popen(["dpkg-deb", part, str(deb)], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|*") as archive:
                for member in archive:
                    path = member.name.lstrip(".")
                    if seen:
                        seen(path)
                    if member.isfile() and member.size < 4 * 1024 ** 2 and wanted(path):
                        found[path] = archive.extractfile(member).read()
        except (tarfile.TarError, OSError):
            pass
        finally:
            process.stdout.close()
            process.kill()
            process.wait()
        return found

    def look(self, deb, token):
        """The app's name and its own icon, from the launcher the package brings (cached: the token is its contents)."""
        cache = self.state / token / "look.json"
        try:
            cached = json.loads(cache.read_text())
            if isinstance(cached, dict) and isinstance(cached.get("sources"), list):   # older ones didn't look for these
                return cached
        except (OSError, ValueError):
            pass
        look = {"title": "", "icon": "", "sources": []}

        def source(path):
            if (path.startswith(SOURCE_FOLDERS) and not path.endswith("/")) or path in SOURCE_FILES:
                if path not in look["sources"]:
                    look["sources"].append(path)
        launchers = self.members(deb, lambda p: p.startswith("/usr/share/applications/") and p.endswith(".desktop"),
                                 seen=source)
        scripts = self.members(deb, lambda p: p in ("/preinst", "/postinst", "/config"), part="--ctrl-tarfile")
        if any(SOURCE_WORDS.search(text) for text in scripts.values()):
            look["sources"].append("its install script")
        look["sources"] = look["sources"][:6]
        icon = ""
        for path in sorted(launchers):
            text = launchers[path].decode(errors="replace")
            if re.search(r"^NoDisplay=true", text, re.M):
                continue
            name = re.search(r"^Name=(.+)$", text, re.M)
            found = re.search(r"^Icon=(.+)$", text, re.M)
            if name and not look["title"]:
                look["title"] = plain(name.group(1), 60)
                icon = found.group(1).strip() if found else ""
        if icon:
            if icon.startswith("/"):
                pictures = self.members(deb, lambda p: p == icon and p.endswith((".png", ".svg")))
            else:
                pictures = self.members(deb, lambda p: ("/icons/" in p or "/pixmaps/" in p)
                                        and os.path.basename(p) in (icon + ".png", icon + ".svg"))
            if pictures:
                best = sorted(pictures, key=lambda p: (not p.endswith(".svg"), -self.icon_size(p)))[0]
                self.icons.mkdir(parents=True, exist_ok=True)
                os.chmod(self.icons, 0o755)
                target = self.icons / (token + os.path.splitext(best)[1])
                target.write_bytes(pictures[best])
                os.chmod(target, 0o644)
                look["icon"] = str(target)
        cache.write_text(json.dumps(look) + "\n")
        return look

    @staticmethod
    def origin(descriptor):
        """The website the file was downloaded from (its name only), when the browser noted it on the file; else ""."""
        try:
            noted = os.getxattr(descriptor, ORIGIN_ATTRIBUTE)[:2048].decode("utf-8", errors="replace")
            address = urllib.parse.urlsplit(noted.strip())
            host = (address.hostname or "").rstrip(".")
        except (OSError, ValueError, TypeError):
            return ""
        if address.scheme not in ("http", "https") or len(host) > 253 or not HOST.fullmatch(host):
            return ""
        return host[4:] if host.startswith("www.") else host

    @staticmethod
    def icon_size(path):
        found = re.search(r"/(\d+)x\d+/", str(path))
        return int(found.group(1)) if found else 0

    # ── Requests ──
    def tidy(self):
        """Copies nobody installed within a day go, with their icons."""
        if not self.state.is_dir():
            return
        for folder in self.state.iterdir():
            try:
                if time.time() - folder.stat().st_mtime > KEEP_SECONDS and not (folder / "running").exists():
                    shutil.rmtree(folder, ignore_errors=True)
                    for icon in self.icons.glob(folder.name + ".*"):
                        icon.unlink(missing_ok=True)
            except OSError:
                pass

    def take(self, descriptor):
        """Copies the open file the window passed into a folder only root can reach. Returns its token."""
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("That isn’t a file.")
        if info.st_size > LIMIT:
            raise ValueError("That file is too large to be an app.")
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)
        work = Path(tempfile.mkdtemp(dir=self.state))
        digest, total = hashlib.sha256(), 0
        with os.fdopen(os.dup(descriptor), "rb") as source, open(work / "package.deb", "wb") as copy:
            source.seek(0)
            while chunk := source.read(1024 * 1024):
                total += len(chunk)
                if total > LIMIT:
                    shutil.rmtree(work, ignore_errors=True)
                    raise ValueError("That file is too large to be an app.")
                digest.update(chunk)
                copy.write(chunk)
        token = digest.hexdigest()[:32]
        folder = self.state / token
        if not folder.exists():
            work.rename(folder)
        elif (folder / "running").exists():
            shutil.rmtree(work, ignore_errors=True)        # it's being installed right now: show that
        else:
            os.replace(work / "package.deb", folder / "package.deb")
            (folder / "status.json").unlink(missing_ok=True)
            shutil.rmtree(work, ignore_errors=True)
            os.utime(folder)
        return token

    def describe(self, token):
        """What the window shows about a package, and whether it can be installed."""
        deb = self.state / token / "package.deb"
        values = self.fields(deb)
        if not values or not NAME.fullmatch(values.get("Package", "")):
            return {"ok": False, "error": "This file isn’t an app HP-OS can install."}
        package, version = values["Package"], plain(values.get("Version"), 80)
        architecture = values.get("Architecture", "")
        maintainer = plain(re.sub(r"\s*<[^>]*>", "", values.get("Maintainer", "")), 80)
        info = {
            "ok": True, "token": token, "package": package, "version": version,
            "name": plain(values.get("Description", package), 90) or package,
            "about": plain(values.get("long", ""), 300),
            "publisher": maintainer, "homepage": plain(values.get("Homepage", ""), 120),
            "size": size_text(int(values["Installed-Size"])) if values.get("Installed-Size", "").isdigit() else "",
            "installed": self.installed_version(package), "allowed": True, "reason": "",
        }
        look = self.look(deb, token)
        info["title"], info["icon"] = look["title"] or info["name"], look["icon"]
        info["addsSource"] = bool(look.get("sources"))
        machine = self.architectures()
        if architecture not in machine + ["all"]:
            kind = {"amd64": "Intel and AMD", "arm64": "ARM", "i386": "older 32-bit"}.get(architecture, architecture)
            here = {"amd64": "an Intel or AMD", "arm64": "an ARM"}.get(machine[0], "this")
            info.update(allowed=False, reason="This version of the app is for %s computers, and this laptop is %s "
                        "computer. If the app’s maker offers a version for %s, download that one instead." % (kind, here,
                        "ARM (sometimes called arm64 or aarch64)" if machine[0] == "arm64" else "Intel and AMD (amd64 or x86_64)"))
        elif values.get("Essential", "").lower() == "yes" or values.get("Priority", "") in ("required", "important") \
                or PROTECTED.fullmatch(package):
            info.update(allowed=False, reason="This would replace a part of HP-OS itself, so it can’t be installed here.")
        elif info["installed"] and self.newer(info["installed"], values.get("Version", "")):
            info.update(allowed=False, reason="A newer version (%s) is already installed." % plain(info["installed"], 40))
        info["isUpdate"] = bool(info["installed"]) and info["installed"] != values.get("Version")
        return info

    def status(self, token):
        try:
            return json.loads((self.state / token / "status.json").read_text())
        except (OSError, ValueError):
            return {"state": "ready"}

    def save(self, token, **values):
        path = self.state / token / "status.json"
        path.write_text(json.dumps(values, ensure_ascii=False) + "\n")
        return values

    def answer(self, uid, message, descriptor=None):
        action = message.get("action")
        tools = device_tools().Device("/")
        who = tools.person(uid)
        if action == "open":
            if descriptor is None:
                return {"ok": False, "error": "This file couldn’t be opened."}
            self.tidy()
            try:
                token = self.take(descriptor)
            except (OSError, ValueError) as error:
                return {"ok": False, "error": str(error) if isinstance(error, ValueError) else "This file couldn’t be read."}
            info = self.describe(token)
            info["admin"] = bool(who) and tools.is_admin(who)
            info["origin"] = self.origin(descriptor)
            return info
        token = str(message.get("token", ""))
        if not re.fullmatch(r"[0-9a-f]{32}", token) or not (self.state / token).is_dir():
            return {"ok": False, "error": "Open the app’s file again."}
        if action == "status":
            return {"ok": True, "status": self.status(token)}
        if action != "install":
            return {"ok": False, "error": "That request isn’t available."}
        if not (self.state / token / "package.deb").is_file():
            return {"ok": False, "error": "Open the app’s file again."}
        if not who or not tools.is_admin(who):
            return {"ok": False, "error": "Only an administrator can install apps."}
        password = message.get("password")
        if not isinstance(password, str) or not password or not tools.password_matches(who, password):
            time.sleep(2)
            return {"ok": False, "error": "That password isn’t correct."}
        if self.status(token).get("state") == "installing":
            return {"ok": True}
        info = self.describe(token)
        if not info.get("ok") or not info.get("allowed"):
            return {"ok": False, "error": info.get("reason") or info.get("error") or "This app can’t be installed."}
        self.save(token, state="installing", progress=2, message="Getting ready…", by=who["name"])
        started = self.run(["/usr/bin/systemctl", "start", "--no-block", "hp-os-app-install-job@%s.service" % token])
        if started.returncode != 0:
            self.save(token, state="error", message="The installer couldn’t start. Restart your laptop and try again.")
            return {"ok": False, "error": "The installer couldn’t start. Restart your laptop and try again."}
        return {"ok": True}

    # ── The install ──
    def apt(self, arguments, progress=None, timeout=1800):
        """apt-get with its progress on a pipe (APT::Status-Fd), reported through progress(percent, kind)."""
        read_end, write_end = os.pipe()
        command = ["apt-get"] + arguments[:1] + ["-o", "APT::Status-Fd=%d" % write_end] + APT_OPTIONS + arguments[1:]
        with tempfile.TemporaryFile("w+", dir=self.state) as output:
            process = subprocess.Popen(command, env=APT_ENV, stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=subprocess.STDOUT, pass_fds=(write_end,), text=True)
            os.close(write_end)
            with os.fdopen(read_end, "r", errors="replace") as updates:
                for line in updates:
                    parts = line.rstrip("\n").split(":", 3)
                    if progress and len(parts) == 4 and parts[0] in ("pmstatus", "dlstatus"):
                        try:
                            progress(float(parts[2]), parts[0])
                        except ValueError:
                            pass
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            output.seek(0)
            return process.returncode, output.read()

    def trial(self, deb):
        """What apt would do, without doing it: (problem for the window or "", apt's output)."""
        code, output = self.apt(["install", "--simulate", "--no-install-recommends", str(deb)])
        if code != 0:
            return "missing", output
        removed = re.findall(r"^Remv (\S+)", output, re.M)
        if removed:
            return ("Installing this app would remove %s from HP-OS, so it wasn’t installed."
                    % ", ".join(removed[:3]) + (" and more" if len(removed) > 3 else "")), output
        for name, old, new in re.findall(r"^Inst (\S+) \[([^\]]+)\] \((\S+)", output, re.M):
            if self.newer(old, new):
                return "Installing this app would put an older version of %s on HP-OS, so it wasn’t installed." % name, output
        return "", output

    def job(self, token):
        folder = self.state / token
        deb = folder / "package.deb"
        info = self.describe(token)
        if not info.get("ok") or not info.get("allowed"):
            return self.save(token, state="error", message=info.get("reason") or "This app can’t be installed.")
        name = info["title"]
        (folder / "running").touch()
        log = folder / "apt.log"
        try:
            self.save(token, state="installing", progress=5, message="Checking what %s needs…" % name)
            problem, output = self.trial(deb)
            if problem == "missing":
                # Installed laptops keep no package list (Intel), or an old one: fetch it, then ask again.
                self.save(token, state="installing", progress=10, message="Finding what %s needs…" % name)
                self.apt(["update"], timeout=600)
                problem, output = self.trial(deb)
            log.write_text(output)
            if problem == "missing":
                return self.save(token, state="error", message="%s needs other software that couldn’t be found. Make "
                                 "sure you’re connected to the internet, then try again." % name)
            if problem:
                return self.save(token, state="error", message=problem)

            def progress(percent, kind):
                # Downloading what it needs is the first part, unpacking and setting up the rest.
                share = 15 + percent * 0.3 if kind == "dlstatus" else 45 + percent * 0.53
                self.save(token, state="installing", progress=round(min(98, share)),
                          message="Downloading what %s needs…" % name if kind == "dlstatus" else "Installing %s…" % name)
            code, output = self.apt(["install", "-y", "--no-install-recommends", str(deb)], progress)
            log.write_text(output)
            if code != 0:
                broken = self.run(["dpkg", "--audit"], capture_output=True, text=True).stdout.strip()
                return self.save(token, state="error", message="%s couldn’t be installed." % name
                                 + (" Restart your laptop before installing anything else." if broken else ""))
            self.run(["update-desktop-database", "-q", "/usr/share/applications"], capture_output=True)
            return self.save(token, state="done", progress=100, message="%s is installed." % name,
                             apps=self.launchers(info["package"]))
        finally:
            (folder / "running").unlink(missing_ok=True)
            if self.status(token).get("state") == "done":
                deb.unlink(missing_ok=True)

    def launchers(self, package):
        found = self.run(["dpkg-query", "-L", package], capture_output=True, text=True)
        apps = []
        for path in found.stdout.splitlines():
            if path.startswith("/usr/share/applications/") and path.endswith(".desktop") and os.path.isfile(path):
                text = Path(path).read_text(errors="replace")
                if re.search(r"^NoDisplay=true", text, re.M):
                    continue
                name = re.search(r"^Name=(.+)$", text, re.M)
                apps.append({"id": os.path.basename(path), "name": plain(name.group(1), 60) if name else package})
        return apps


def receive(connection):
    """The request line, and the file passed with it if any."""
    data, descriptors = b"", []
    while b"\n" not in data and len(data) < 8192:
        message, ancillary, _, _ = connection.recvmsg(8192, socket.CMSG_SPACE(struct.calcsize("i")))
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                passed = array.array("i")
                passed.frombytes(payload[:len(payload) - len(payload) % passed.itemsize])
                descriptors.extend(passed)
        if not message:
            break
        data += message
    for extra in descriptors[1:]:
        os.close(extra)
    return data.split(b"\n", 1)[0].decode("utf-8", errors="replace"), descriptors[0] if descriptors else None


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    installer = Installer()
    if command == "request":
        connection = socket.socket(fileno=0)
        uid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
        descriptor = None
        try:
            line, descriptor = receive(connection)
            message = json.loads(line)
            reply = installer.answer(uid, message if isinstance(message, dict) else {}, descriptor)
        except ValueError:
            reply = {"ok": False, "error": "That request isn’t available."}
        finally:
            if descriptor is not None:
                os.close(descriptor)
        connection.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode())
    elif command == "job" and len(sys.argv) == 3 and re.fullmatch(r"[0-9a-f]{32}", sys.argv[2]):
        installer.job(sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
