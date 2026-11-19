#!/usr/bin/python3
"""HP-OS software updates on a device, run as root by the units hp-os-device-setup.sh installs.

  hp-os-update check          look for a new release (a daily timer, or Settings)
  hp-os-update settle         at startup: an update that was waiting for a restart has now finished
  hp-os-update job            carry out the install or restore that was asked for
  hp-os-update request        answer Settings (socket activated)
  hp-os-update enroll FILE    connect this device to its publisher, from the bundle made on the publishing laptop
  hp-os-update status         print the current state

Nothing is changed until a release has passed every check: signed by the publisher, exactly the files that were
signed, newer than what is installed, and fully built. People's files are never touched, and if installing fails
the version that was working is put back.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import hp_os_release as release  # noqa: E402

UPDATER = "hp-os-updater"
MINIMUM_FREE_GB = 15
MINIMUM_BATTERY = 30
CHIPS = {"aarch64": "aarch64-linux", "arm64": "aarch64-linux", "x86_64": "x86_64-linux", "amd64": "x86_64-linux"}
NIX_SETTINGS = "etc/nix/nix.conf"
NETRC = "etc/nix/hp-os-updates.netrc"
BEGIN, END = "# HP-OS ready-built updates (managed by hp-os-update)", "# end of HP-OS ready-built updates"
GITHUB_KEY = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"


class Stop(Exception):
    """A reason the person can act on."""


def device_tools():
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hp-os-device")
    loader = importlib.machinery.SourceFileLoader("hp_os_device", path)
    spec = importlib.util.spec_from_loader("hp_os_device", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Updater:
    def __init__(self, root="/"):
        self.root = Path(root)
        self.config_dir = self.root / "etc/hp-os/update"
        self.state = self.root / "var/lib/hp-os/update"
        self.status_file = self.state / "status.json"
        self.job_file = self.state / "job"
        self.mirror = self.state / "mirror.git"
        self.versions = self.state / "versions"
        self.signers = self.config_dir / "allowed_signers"

    # ── What Settings shows ──
    def status(self):
        try:
            found = json.loads(self.status_file.read_text())
        except (OSError, ValueError):
            found = {}
        found["enrolled"] = self.enrolled()
        found.setdefault("state", "idle")
        found["installed"] = self.installed()
        found["previous"] = self.previous()
        return found

    def save(self, **changes):
        current = self.status()
        current.update(changes)
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o755)
        temporary = self.status_file.with_suffix(".new")
        temporary.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, self.status_file)
        return current

    def enrolled(self):
        return (self.config_dir / "config.json").is_file() and self.signers.is_file()

    def installed(self):
        try:
            return json.loads((self.state / "installed.json").read_text()).get("version", "")
        except (OSError, ValueError):
            return ""

    def previous(self):
        try:
            return json.loads((self.state / "installed.json").read_text()).get("previous", "")
        except (OSError, ValueError):
            return ""

    # ── Talking to the release repository, as the unprivileged updater account ──
    def as_updater(self, command, check=True, timeout=None):
        key = self.config_dir / "deploy-key"
        ssh = "/usr/bin/ssh -i %s -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s" % (
            key, self.config_dir / "known_hosts")
        environment = {"HOME": str(self.state / "home"), "PATH": "/usr/bin:/bin", "GIT_SSH_COMMAND": ssh,
                       "GIT_TERMINAL_PROMPT": "0", "NIX_CONFIG": "experimental-features = nix-command flakes"}
        prefix = ["/usr/sbin/runuser", "-u", UPDATER, "--", "/usr/bin/env"] + ["%s=%s" % item for item in environment.items()]
        return subprocess.run(prefix + command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout, check=check)

    def repository(self):
        return json.loads((self.config_dir / "config.json").read_text())["repository"]

    def fetch(self):
        self.mirror.parent.mkdir(parents=True, exist_ok=True)
        if not (self.mirror / "HEAD").exists():
            self.mirror.mkdir(exist_ok=True)
            shutil.chown(self.mirror, UPDATER)
            self.as_updater(["/usr/bin/git", "init", "--quiet", "--bare", str(self.mirror)])
        self.as_updater(["/usr/bin/git", "-C", str(self.mirror), "fetch", "--quiet", "--force", self.repository(),
                         "+refs/heads/%s:refs/heads/%s" % (release.CHANNEL, release.CHANNEL),
                         "+refs/heads/%s:refs/heads/%s" % (release.STABLE, release.STABLE)], timeout=1800)

    def git(self, *arguments, text=True):
        result = subprocess.run(["/usr/bin/git", "-c", "safe.directory=*", "-C", str(self.mirror)] + list(arguments),
                                capture_output=True, check=True, text=text)
        return result.stdout

    def latest(self):
        """The newest release, only if the publisher really signed it."""
        data = self.git("show", "%s:latest.json" % release.CHANNEL, text=False)
        signature = self.git("show", "%s:latest.json.sig" % release.CHANNEL, text=False)
        with tempfile.NamedTemporaryFile() as stored:
            stored.write(signature)
            stored.flush()
            if not release.signature_valid(data, stored.name, self.signers):
                raise Stop("This update isn’t signed by your publisher, so it wasn’t installed.")
        manifest = json.loads(data)
        release.version_key(manifest["version"])
        return manifest

    def newer(self, manifest):
        installed = self.installed()
        return not installed or release.version_key(manifest["version"]) > release.version_key(installed)

    # ── Ready-built updates ──
    def chip(self):
        return CHIPS.get(os.uname().machine, os.uname().machine)

    def ready_for_this_device(self, manifest):
        """A release that lists ready-built chips is offered to a device once its own chip is among them."""
        return "prebuilt" not in manifest or self.chip() in manifest.get("prebuilt", [])

    def use_ready_built(self, manifest):
        """Lets Nix download this release's parts (signed by the publisher) instead of building them. Returns True when
        anything changed, so the Nix service picks it up."""
        cache = manifest.get("cache")
        if not isinstance(cache, dict) or not all(isinstance(cache.get(key), str) and cache[key]
                                                  for key in ("url", "publicKey", "login", "password")):
            return False
        found = re.fullmatch(r"https://([a-z0-9.-]+)/?", cache["url"])
        if not found or not re.fullmatch(r"[\w.-]+:[A-Za-z0-9+/=]+", cache["publicKey"]) \
                or not re.fullmatch(r"[\w-]{1,32}", cache["login"]) or not re.fullmatch(r"[\w-]{20,128}", cache["password"]):
            return False
        changed = False
        netrc = self.root / NETRC
        wanted = "machine %s login %s password %s\n" % (found.group(1), cache["login"], cache["password"])
        if not netrc.is_file() or netrc.read_text() != wanted:
            netrc.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(netrc, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                stream.write(wanted)
            os.chmod(netrc, 0o600)
            changed = True
        settings = self.root / NIX_SETTINGS
        current = settings.read_text() if settings.is_file() else ""
        kept = re.sub(r"\n?%s\n.*?%s\n?" % (re.escape(BEGIN), re.escape(END)), "\n", current, flags=re.S).rstrip("\n")
        block = "%s\nextra-substituters = %s\nextra-trusted-public-keys = %s\nnetrc-file = /%s\n%s\n" % (
            BEGIN, cache["url"].rstrip("/"), cache["publicKey"], NETRC, END)
        wanted_settings = (kept + "\n\n" if kept else "") + block
        if current != wanted_settings:
            settings.parent.mkdir(parents=True, exist_ok=True)
            settings.write_text(wanted_settings)
            changed = True
        return changed

    def restart_nix(self):
        subprocess.run(["/usr/bin/systemctl", "try-restart", "nix-daemon.service"], check=False)

    def unpack(self, manifest):
        """The signed files, and only those, in their own folder."""
        target = self.versions / manifest["version"]
        shutil.rmtree(target, ignore_errors=True)
        target.mkdir(parents=True)
        archive = subprocess.Popen(["/usr/bin/git", "-c", "safe.directory=*", "-C", str(self.mirror), "archive",
                                    manifest["commit"]], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=archive.stdout, mode="r|") as bundle:
            bundle.extractall(target, filter="tar")
        if archive.wait() != 0 or release.tree_digest(target) != manifest["digest"]:
            shutil.rmtree(target, ignore_errors=True)
            raise Stop("This update didn’t match what was signed, so it wasn’t installed.")
        return target     # Stays root's: what was verified is what gets installed.

    # ── Checks before anything starts ──
    def ready_to_install(self):
        free = shutil.disk_usage(self.state).free / 1024 ** 3
        if free < MINIMUM_FREE_GB:
            raise Stop("Free up at least %d GB of storage, then try again." % MINIMUM_FREE_GB)
        supplies = Path("/sys/class/power_supply")
        on_power = any((path / "online").read_text().strip() == "1" for path in supplies.glob("ADP*") if (path / "online").exists())
        for battery in supplies.glob("BAT*"):
            if not on_power and int((battery / "capacity").read_text()) < MINIMUM_BATTERY:
                raise Stop("Plug in your device, or charge it to %d%%, then try again." % MINIMUM_BATTERY)

    def accounts(self):
        names = []
        for line in (self.root / "etc/passwd").read_text().splitlines():
            fields = line.split(":")
            if len(fields) >= 7 and fields[2].isdigit() and 1000 <= int(fields[2]) < 60000 and fields[5] == "/home/" + fields[0]:
                names.append(fields[0])
        return names

    def build(self, source):
        """Everything is built before the device changes at all."""
        flake = "path:%s" % source
        targets = ["%s#hp-os-account-setup" % flake, "%s#hp-os-add-user" % flake, "%s#hp-os-login-theme" % flake]
        self.as_updater(["/usr/bin/nix", "build", "--no-link"] + targets, timeout=14400)
        for name in self.accounts():
            expression = '((builtins.getFlake "%s").lib.hpOsAccount "%s").activationPackage' % (flake, name)
            self.as_updater(["/usr/bin/nix", "build", "--no-link", "--impure", "--expr", expression], timeout=14400)

    def apply(self, source):
        """The same installer this device was set up with, from the verified release."""
        environment = dict(os.environ, SUDO_USER=UPDATER, PATH="/usr/sbin:/usr/bin:/sbin:/bin", HOME="/root")
        result = subprocess.run([str(Path(source) / "goran/installer/system/hp-os-add-user.sh")], env=environment,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=7200, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr[-2000:])

    def record(self, version, previous):
        data = json.dumps({"version": version, "previous": previous, "at": int(time.time())}) + "\n"
        (self.state / "installed.json").write_text(data)
        keep = {version, previous}
        for folder in self.versions.iterdir():
            if folder.name not in keep:
                shutil.rmtree(folder, ignore_errors=True)

    def notify(self, offer):
        """Once per version, a notification for whoever is signed in."""
        if self.status().get("notified") == offer["version"]:
            return
        self.save(notified=offer["version"])
        for bus in Path("/run/user").glob("*/bus"):
            uid = bus.parent.name
            if not uid.isdigit() or int(uid) < 1000:
                continue
            subprocess.run(["/usr/sbin/runuser", "-u", "#" + uid, "--", "/usr/bin/env", "DBUS_SESSION_BUS_ADDRESS=unix:path=%s" % bus,
                            "/usr/bin/notify-send", "-a", "Software Update", "-i", "system-software-update",
                            "HP-OS %s is available" % offer["version"], "Open Settings to install it."],
                           check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def settle(self):
        """After the restart an update asked for, it is simply installed: Settings stops asking to restart."""
        if self.status().get("state") == "restart" and self.restarted_since_install():
            return self.save(state="idle", message="", progress=0)
        return self.status()

    def restarted_since_install(self):
        try:
            installed_at = json.loads((self.state / "installed.json").read_text()).get("at", 0)
            uptime = float(Path("/proc/uptime").read_text().split()[0])
        except (OSError, ValueError, IndexError):
            return False
        return installed_at < time.time() - uptime

    # ── The three things this device can be asked to do ──
    def check(self):
        if not self.enrolled():
            return self.save(state="idle")
        self.settle()
        if self.status().get("state") in ("downloading", "installing", "restoring"):
            return self.status()
        try:
            self.fetch()
            manifest = self.latest()
        except (subprocess.SubprocessError, OSError, ValueError, KeyError, Stop) as error:
            message = str(error) if isinstance(error, Stop) else "Couldn’t reach the update server."
            return self.save(lastChecked=int(time.time()), checkError=message)
        offer = {key: manifest.get(key, "") for key in ("version", "notes", "date")}
        if not self.newer(manifest) or not self.ready_for_this_device(manifest):
            state = self.status().get("state")
            return self.save(state="restart" if state == "restart" else "idle", available=None, lastChecked=int(time.time()),
                             checkError="")
        self.notify(offer)
        return self.save(state="available", available=offer, lastChecked=int(time.time()), checkError="", message="")

    def install(self):
        current = self.installed()
        current_source = self.versions / current if current else None
        try:
            self.save(state="downloading", progress=5, message="Downloading…")
            self.ready_to_install()
            self.fetch()
            manifest = self.latest()
            if not self.newer(manifest) or not self.ready_for_this_device(manifest):
                return self.save(state="idle", available=None, progress=0, message="")
            source = self.unpack(manifest)
            if self.use_ready_built(manifest):
                self.restart_nix()
            self.save(state="downloading", progress=20, message="Preparing the update. This can take a while…")
            self.build(source)
        except (Stop, subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
            reason = str(error) if isinstance(error, Stop) else "The update couldn’t be downloaded. Your device wasn’t changed."
            return self.save(state="error", message=reason, progress=0)
        try:
            self.save(state="installing", progress=75, message="Installing…")
            self.apply(source)
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            print("install failed: %s" % error, file=sys.stderr)
            self.save(state="restoring", progress=85, message="Putting the previous version back…")
            restored = False
            if current_source and current_source.is_dir():
                try:
                    self.apply(current_source)
                    restored = True
                except (RuntimeError, subprocess.SubprocessError, OSError) as second:
                    print("restore failed: %s" % second, file=sys.stderr)
            return self.save(state="error", progress=0, message="The update couldn’t be installed. "
                             + ("Your device is back on the previous version." if restored else "Restart your device."))
        self.record(manifest["version"], current)
        return self.save(state="restart", installed=manifest["version"], available=None, progress=100,
                         message="Restart to finish updating.")

    def restore(self):
        previous = self.previous()
        source = self.versions / previous if previous else None
        if not source or not source.is_dir():
            return self.save(state="error", message="There’s no earlier version on this device.", progress=0)
        current = self.installed()
        try:
            self.save(state="restoring", progress=40, message="Putting the previous version back…")
            self.apply(source)
        except (RuntimeError, subprocess.SubprocessError, OSError):
            return self.save(state="error", progress=0, message="The previous version couldn’t be restored.")
        (self.state / "installed.json").write_text(json.dumps({"version": previous, "previous": "", "at": int(time.time())}) + "\n")
        shutil.rmtree(self.versions / current, ignore_errors=True)
        return self.save(state="restart", installed=previous, progress=100, message="Restart to finish.")

    def job(self):
        try:
            action = self.job_file.read_text().strip()
            self.job_file.unlink()
        except OSError:
            return self.status()
        return self.restore() if action == "restore" else self.install()

    def answer(self, uid, message):
        action = message.get("action")
        if action == "status":
            tools = device_tools().Device(self.root)
            who = tools.person(uid)
            return {"ok": True, "status": self.settle(), "admin": bool(who) and tools.is_admin(who)}
        if action == "check":
            subprocess.run(["/usr/bin/systemctl", "start", "--no-block", "hp-os-update-check.service"], check=False)
            return {"ok": True}
        if action not in ("install", "restore"):
            return {"ok": False, "error": "That request isn’t available."}
        tools = device_tools().Device(self.root)
        who = tools.person(uid)
        if not who or not tools.is_admin(who):
            return {"ok": False, "error": "Only an administrator can install updates."}
        password = message.get("password")
        if not isinstance(password, str) or not password or not tools.password_matches(who, password):
            time.sleep(2)
            return {"ok": False, "error": "That password isn’t correct."}
        if self.status().get("state") in ("downloading", "installing", "restoring"):
            return {"ok": True}
        self.job_file.write_text(action + "\n")
        subprocess.run(["/usr/bin/systemctl", "start", "--no-block", "hp-os-update-job.service"], check=False)
        return {"ok": True}

    def enroll(self, bundle):
        with tempfile.TemporaryDirectory() as folder:
            with tarfile.open(bundle) as archive:
                archive.extractall(folder, filter="data")
            config = json.loads(Path(folder, "config.json").read_text())
            if not re.fullmatch(r"git@github\.com:[\w.-]+/[\w.-]+\.git|/[\w./-]+", config.get("repository", "")):
                raise SystemExit("That bundle doesn’t name a release repository.")
            signer = Path(folder, "allowed_signers").read_text()
            if not signer.startswith(release.IDENTITY + " "):
                raise SystemExit("That bundle has no publisher key.")
            self.config_dir.mkdir(parents=True, exist_ok=True)
            os.chmod(self.config_dir, 0o755)
            (self.config_dir / "config.json").write_text(json.dumps({"repository": config["repository"]}) + "\n")
            self.signers.write_text(signer)
            (self.config_dir / "known_hosts").write_text(GITHUB_KEY)
            shutil.copyfile(Path(folder, "deploy-key"), self.config_dir / "deploy-key")
        shutil.chown(self.config_dir / "deploy-key", UPDATER)
        os.chmod(self.config_dir / "deploy-key", 0o600)
        self.save(state="idle")
        subprocess.run(["/usr/bin/systemctl", "start", "--no-block", "hp-os-update-check.service"], check=False)
        print("This device now receives HP-OS updates.")


def main():
    import socket
    import struct
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    updater = Updater()
    if command == "check":
        updater.check()
    elif command == "settle":
        updater.settle()
    elif command == "job":
        updater.job()
    elif command == "status":
        print(json.dumps(updater.status(), indent=2, ensure_ascii=False))
    elif command == "enroll" and len(sys.argv) == 3:
        updater.enroll(sys.argv[2])
    elif command == "request":
        connection = socket.socket(fileno=0)
        uid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
        try:
            message = json.loads(connection.makefile("r", encoding="utf-8", errors="replace").readline(4096))
            reply = updater.answer(uid, message if isinstance(message, dict) else {})
        except ValueError:
            reply = {"ok": False, "error": "That request isn’t available."}
        connection.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
