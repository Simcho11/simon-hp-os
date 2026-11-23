#!/usr/bin/python3
"""HP-OS software updates on a device, run as root by the units hp-os-device-setup.sh installs.

  hp-os-update check          look for a new release (a daily timer, or Settings)
  hp-os-update settle         at startup: an update that was waiting for a restart has now finished
  hp-os-update job            carry out the install or restore that was asked for
  hp-os-update request        answer Settings (socket activated)
  hp-os-update enroll FILE    connect this device to its publisher, from the bundle made on the publishing laptop
  hp-os-update status         print the current state
  hp-os-update clock          set the clock from the internet, on a device with nothing else that does
  hp-os-update selftest       check a newly installed updater works before it replaces the old one

Nothing is changed until a release has passed every check: signed by the publisher, exactly the files that were
signed, newer than what is installed, and fully built. People's files are never touched, and if installing fails
the version that was working is put back. An install cut off halfway (the battery, a crash) is never left half done:
at the next start the version that was working is put back by itself.
"""
import importlib.machinery
import importlib.util
import email.utils
import fcntl
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
BUSY = ("downloading", "installing", "restoring")
# Versions kept on the device: this one and the one before it (Settings can go back to it).
KEEP_GENERATIONS = 2
CLEAN_UP_SECONDS = 1200
REPAIR_TRIES = 2
CHIPS = {"aarch64": "aarch64-linux", "arm64": "aarch64-linux", "x86_64": "x86_64-linux", "amd64": "x86_64-linux"}
NIX_SETTINGS = "etc/nix/nix.conf"
NETRC = "etc/nix/hp-os-updates.netrc"
BEGIN, END = "# HP-OS ready-built updates (managed by hp-os-update)", "# end of HP-OS ready-built updates"
PUBLIC_CACHE = "https://cache.nixos.org"
MEASURE_SECONDS = 110
UNITS = {"B": 1, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4}
# Where a device without its own time service (chrony, timesyncd) reads the time: two HTTPS sites the updater uses
# anyway. Their Date headers have to agree, and TLS keeps them honest.
CLOCK_SOURCES = ("https://cache.nixos.org/nix-cache-info", "https://github.com/")
TIME_SERVICES = ("usr/sbin/chronyd", "lib/systemd/systemd-timesyncd", "usr/lib/systemd/systemd-timesyncd")
GITHUB_KEY = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"


class Stop(Exception):
    """A reason the person can act on."""


def write_atomic(path, text, mode=0o644):
    """The whole file or the old one, never half of it, even if the power goes in the middle."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    try:
        folder = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(folder)
        finally:
            os.close(folder)
    except OSError:
        pass


def device_tools():
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hp-os-device")
    loader = importlib.machinery.SourceFileLoader("hp_os_device", path)
    spec = importlib.util.spec_from_loader("hp_os_device", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def internet_time(run=subprocess.run):
    """The time now, from the Date headers of CLOCK_SOURCES, or None if they can't be reached or don't agree."""
    found = []
    for url in CLOCK_SOURCES:
        started = time.time()
        try:
            headers = run(["/usr/bin/curl", "-fsSI", "--max-time", "8", url], capture_output=True, text=True, timeout=12).stdout
            date = re.search(r"^date:[ \t]*(.+?)\r?$", headers, re.IGNORECASE | re.MULTILINE)
            if date:
                found.append(email.utils.parsedate_to_datetime(date.group(1)).timestamp() + (time.time() - started) / 2)
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            continue
    if not found or (len(found) > 1 and max(found) - min(found) > 30):
        return None
    return sum(found) / len(found)


def set_clock(root=Path("/"), run=subprocess.run, now=time.time):
    """On a device with no time service, a clock more than a minute out is set from the internet, and its hardware
    clock too, so the next start is right. Returns how many seconds it moved (0 when it was left alone)."""
    if any((root / service).exists() for service in TIME_SERVICES):
        return 0
    actual = internet_time(run)
    if actual is None or abs(actual - now()) < 60:
        return 0
    moved = actual - now()
    if run(["/usr/bin/date", "-u", "-s", "@%d" % round(actual)], capture_output=True, check=False).returncode != 0:
        return 0
    if (root / "usr/sbin/hwclock").exists():
        run(["/usr/sbin/hwclock", "--systohc", "--utc"], capture_output=True, check=False)
    return moved


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
        write_atomic(self.status_file, json.dumps(current, indent=2, ensure_ascii=False) + "\n")
        return current

    def lock(self, wait=True):
        """One check, install or restore at a time: they share the release mirror and the unpacked versions. Returns
        the held lock (closing it lets go), or None when something else holds it and wait is False."""
        self.state.mkdir(parents=True, exist_ok=True)
        handle = open(self.state / "lock", "a")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            handle.close()
            return None
        return handle

    def job_running(self, lock_held=False):
        """An install or restore running right now (also one started by an updater from before the lock existed).
        lock_held: this process holds the lock already (a second flock here would only ever see itself)."""
        if not lock_held:
            held = self.lock(wait=False)
            if held is None:
                return True
            held.close()
        if self.root != Path("/"):
            return False
        return subprocess.run(["/usr/bin/systemctl", "is-active", "--quiet", "hp-os-update-job.service"],
                              check=False).returncode == 0

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
            write_atomic(settings, wanted_settings)
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
        try:
            with tarfile.open(fileobj=archive.stdout, mode="r|") as bundle:
                bundle.extractall(target, filter="tar")
        except tarfile.TarError:
            archive.kill()
            archive.wait()
            shutil.rmtree(target, ignore_errors=True)
            raise Stop("This update couldn’t be read, so it wasn’t installed. Try again later.")
        if archive.wait() != 0 or release.tree_digest(target) != manifest["digest"]:
            shutil.rmtree(target, ignore_errors=True)
            raise Stop("This update didn’t match what was signed, so it wasn’t installed.")
        return target     # Stays root's: what was verified is what gets installed.

    # ── Checks before anything starts ──
    def free_gb(self):
        return shutil.disk_usage(self.state).free / 1024 ** 3

    def ready_to_install(self):
        if self.free_gb() < MINIMUM_FREE_GB:
            # Old versions first: they are usually what fills the disk, and the person can't remove them.
            self.clean_up()
        if self.free_gb() < MINIMUM_FREE_GB:
            raise Stop("Free up at least %d GB of storage, then try again." % MINIMUM_FREE_GB)
        supplies = self.root / "sys/class/power_supply"
        if not self.on_power(supplies):
            for battery in supplies.glob("BAT*"):
                try:
                    capacity = int((battery / "capacity").read_text())
                except (OSError, ValueError):
                    continue
                if capacity < MINIMUM_BATTERY:
                    raise Stop("Plug in your device, or charge it to %d%%, then try again." % MINIMUM_BATTERY)

    @staticmethod
    def on_power(supplies):
        """Plugged in, by the kind of supply rather than its name: ARM laptops call the charger ADP1, Intel ones often
        AC or a USB-C port."""
        try:
            found = list(supplies.iterdir())
        except OSError:
            return False
        for path in found:
            try:
                kind = (path / "type").read_text().strip() if (path / "type").exists() else ""
                online = (path / "online").read_text().strip() == "1"
            except OSError:
                continue
            if online and (kind in ("Mains", "USB", "USB_C", "USB_PD", "USB_PD_DRP") or path.name.startswith(("ADP", "AC"))):
                return True
        return False

    # ── Old versions ──
    def profiles(self):
        """The device's own Nix profiles (the login screen, Add user, first-login setup), not their numbered versions."""
        folder = self.root / "nix/var/nix/profiles"
        return sorted(path for path in folder.glob("hp-os-*") if path.is_symlink() and not re.search(r"-\d+-link$", path.name))

    def clean_up(self):
        """Removes versions older than this one and the one before it: the device's own parts, each account's desktop,
        and what nothing uses any more. Runs only when no session can still be using an older version (after the
        restart an update asks for), and never fails an update. Parts a new account needs to be set up without the
        internet are kept: the release's sources are held by first-login setup itself, and with keep-outputs the
        build tools of every kept desktop stay too."""
        if self.root != Path("/"):
            return False
        # A session signed in before the last install still runs the version before it, file by file.
        if (self.state / "installed.json").exists() and not self.restarted_since_install():
            return False
        quiet = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.PIPE, "text": True, "check": False}
        try:
            for profile in self.profiles():
                subprocess.run(["/usr/bin/nix-env", "--profile", str(profile), "--delete-generations", "+%d" % KEEP_GENERATIONS],
                               timeout=300, **quiet)
            for name in self.accounts():
                profile = self.root / "home" / name / ".local/state/nix/profiles/home-manager"
                if profile.is_symlink():
                    subprocess.run(["/usr/sbin/runuser", "-u", name, "--", "/usr/bin/nix-env", "--profile", str(profile),
                                    "--delete-generations", "+%d" % KEEP_GENERATIONS], timeout=300, **quiet)
            subprocess.run(["/usr/bin/nice", "-n", "19", "/usr/bin/ionice", "-c", "3", "/usr/bin/nix-store", "--gc",
                            "--option", "keep-outputs", "true", "--option", "keep-derivations", "true"],
                           timeout=CLEAN_UP_SECONDS, **quiet)
        except (OSError, subprocess.SubprocessError) as error:
            print("clean-up stopped: %s" % error, file=sys.stderr)
            return False
        self.save(cleanedFor=self.installed())
        return True

    def accounts(self):
        names = []
        for line in (self.root / "etc/passwd").read_text().splitlines():
            fields = line.split(":")
            if len(fields) >= 7 and fields[2].isdigit() and 1000 <= int(fields[2]) < 60000 and fields[5] == "/home/" + fields[0]:
                names.append(fields[0])
        return names

    # ── How big an update is, and how long it takes here ──
    def everything(self, source):
        """One Nix expression for everything an update builds: the system parts and each account's desktop."""
        flake = "path:%s" % source
        names = " ".join(json.dumps(name) for name in self.accounts())
        return ('let f = builtins.getFlake "%s"; p = f.packages.${builtins.currentSystem}; in '
                '[ p.hp-os-account-setup p.hp-os-add-user p.hp-os-login-theme ] ++ '
                'map (name: (f.lib.hpOsAccount name).activationPackage) [ %s ]' % (flake, names))

    @staticmethod
    def download_size(report):
        """What `nix build --dry-run` says it would download: (bytes, paths to fetch, things to build)."""
        size = 0
        found = re.search(r"will be fetched \(([\d.]+) (B|KiB|MiB|GiB|TiB) download", report)
        if found:
            size = int(float(found.group(1)) * UNITS[found.group(2)])
        fetched = re.findall(r"^\s+(/nix/store/[a-z0-9]{32}-\S+)$", report.split("will be fetched", 1)[1], re.M) \
            if "will be fetched" in report else []
        built = re.search(r"(?:these (\d+) derivations|(this) derivation) will be built", report)
        builds = int(built.group(1)) if built and built.group(1) else (1 if built else 0)
        return size, fetched, builds

    def download_speed(self, paths):
        """Bytes per second from this device, timed on a few megabytes of one part the update needs from the public
        cache (which most of an update comes from). 0 when it can't be measured."""
        for path in paths[:40]:
            name = Path(path).name.split("-")[0]
            try:
                info = subprocess.run(["/usr/bin/curl", "-fsS", "--max-time", "10", "%s/%s.narinfo" % (PUBLIC_CACHE, name)],
                                      capture_output=True, text=True, timeout=15).stdout
            except (OSError, subprocess.SubprocessError):
                return 0
            fields = dict(line.split(": ", 1) for line in info.splitlines() if ": " in line)
            if int(fields.get("FileSize", "0") or 0) < 2_000_000 or "URL" not in fields:
                continue
            sample = min(int(fields["FileSize"]), 8_000_000) - 1
            try:
                timing = subprocess.run(["/usr/bin/curl", "-fsS", "--max-time", "20", "-r", "0-%d" % sample, "-o", "/dev/null",
                                         "-w", "%{size_download} %{time_total}", "%s/%s" % (PUBLIC_CACHE, fields["URL"])],
                                        capture_output=True, text=True, timeout=25).stdout.split()
                received, seconds = int(timing[0]), float(timing[1])
            except (OSError, subprocess.SubprocessError, ValueError, IndexError):
                return 0
            return int(received / seconds) if received > 500_000 and seconds > 0 else 0
        return 0

    def measure(self, manifest):
        """Download size and an estimate of how long the update takes on this device, for Settings and first-time
        setup. Empty when it can't be worked out; the update itself doesn't depend on it."""
        try:
            source = self.unpack(manifest)
            if self.use_ready_built(manifest):
                self.restart_nix()
            # At most two minutes: on a brand-new device it has to fetch everything first, and nobody should wait on
            # a size. Past that the update is offered without one (timeout stops nix itself, not just runuser).
            result = self.as_updater(["/usr/bin/timeout", str(MEASURE_SECONDS), "/usr/bin/nix", "build", "--dry-run", "--impure",
                                      "--expr", self.everything(source)], check=False, timeout=MEASURE_SECONDS + 30)
        except (Stop, subprocess.SubprocessError, OSError, ValueError, KeyError):
            return {}
        if result.returncode != 0:
            return {}
        size, fetched, builds = self.download_size(result.stderr)
        speed = self.download_speed(fetched) if size else 0
        found = {"downloadBytes": size, "builds": builds}
        if speed:
            # Downloading, unpacking about twice as much, building what isn't ready-built, then switching over.
            found["estimateSeconds"] = int(size / speed * 1.2 + size / 60_000_000 + builds * 30 + 90)
        elif not size:
            found["estimateSeconds"] = 60 + builds * 30
        return found

    def build(self, source):
        """Everything is built before the device changes at all."""
        flake = "path:%s" % source
        targets = ["%s#hp-os-account-setup" % flake, "%s#hp-os-add-user" % flake, "%s#hp-os-login-theme" % flake]
        self.as_updater(["/usr/bin/nix", "build", "--no-link"] + targets, timeout=14400)
        for name in self.accounts():
            expression = '((builtins.getFlake "%s").lib.hpOsAccount "%s").activationPackage' % (flake, name)
            self.as_updater(["/usr/bin/nix", "build", "--no-link", "--impure", "--expr", expression], timeout=14400)

    def apply(self, source):
        """The same installer this device was set up with, from the verified release. While it runs the device can't be
        shut down or put to sleep from the desktop (closing the lid included): that is the one moment it would be left
        half one version, half the other."""
        environment = dict(os.environ, SUDO_USER=UPDATER, PATH="/usr/sbin:/usr/bin:/sbin:/bin", HOME="/root")
        with self.keep_on():
            result = subprocess.run([str(Path(source) / "goran/installer/system/hp-os-add-user.sh")], env=environment,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=7200, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr[-2000:])

    def keep_on(self):
        """Holds off shutdown and sleep for as long as the with-block runs. The holder reads from a pipe, so it lets go
        even if this process dies; an almost empty battery still shuts down (the system's own last resort)."""
        updater = self

        class Hold:
            def __enter__(self):
                self.process = None
                if updater.root == Path("/") and Path("/usr/bin/systemd-inhibit").exists():
                    try:
                        self.process = subprocess.Popen(
                            ["/usr/bin/systemd-inhibit", "--what=shutdown:sleep:handle-lid-switch", "--who=HP-OS",
                             "--why=Installing an update", "--mode=block", "/usr/bin/cat"],
                            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except OSError:
                        self.process = None
                return self

            def __exit__(self, *_):
                if self.process:
                    try:
                        self.process.stdin.close()
                        self.process.wait(timeout=10)
                    except (OSError, subprocess.SubprocessError):
                        self.process.kill()
                return False

        return Hold()

    def record(self, version, previous):
        data = json.dumps({"version": version, "previous": previous, "at": int(time.time()), "boot": self.boot_id()}) + "\n"
        write_atomic(self.state / "installed.json", data)
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

    def settle(self, recover=False, lock_held=False):
        """After the restart an update asked for, it is simply installed: Settings stops asking to restart.
        recover: an install or restore that was cut off (the power, a crash) is finished off instead of staying "busy"
        for ever. Only at startup and in the daily check, which hold the lock: Settings asking for the state never
        decides it."""
        status = self.status()
        if status.get("state") == "restart" and self.restarted_since_install():
            return self.save(state="idle", message="", progress=0)
        if recover and status.get("state") in BUSY and not self.job_running(lock_held=lock_held):
            return self.recover(status)
        return status

    def settle_at_start(self):
        held = self.lock(wait=False)
        if held is None:
            return self.status()
        try:
            return self.settle(recover=True, lock_held=True)
        finally:
            held.close()

    def recover(self, status):
        """Nothing changes on the device until "installing", so a download cut off left it as it was. Once installing
        has started the device may be part old, part new: the version that was working is put back by itself (an
        update the person asked for is then offered again). Tried twice at most, so a repeated cut-off can't loop."""
        print("an update was interrupted while %s" % status.get("state"), file=sys.stderr)
        if status.get("state") == "downloading":
            return self.save(state="error", progress=0, message="The update was interrupted before it changed anything. "
                             "Try again.")
        tries = int(status.get("repairTries") or 0)
        if tries >= REPAIR_TRIES:
            return self.save(state="error", progress=0, repairTries=0,
                             message="The update was interrupted and couldn’t be finished. Restart your device, then install "
                                     "the update again.")
        write_atomic(self.job_file, "repair\n")
        self.save(state="installing", progress=10, message="Finishing an update that was interrupted…", repairTries=tries + 1)
        if self.root == Path("/"):
            subprocess.run(["/usr/bin/systemctl", "start", "--no-block", "hp-os-update-job.service"], check=False)
        return self.status()

    def boot_id(self):
        """This start of the device: a new one at every restart, whatever the clock says."""
        try:
            return (self.root / "proc/sys/kernel/random/boot_id").read_text().strip()
        except OSError:
            return ""

    def restarted_since_install(self):
        """By the start the install happened in, not by the clock: a laptop whose clock starts hours off (Windows
        keeps it in local time) would otherwise keep asking for a restart it already had."""
        try:
            record = json.loads((self.state / "installed.json").read_text())
        except (OSError, ValueError):
            return False
        now = self.boot_id()
        if record.get("boot") and now:
            return record["boot"] != now
        try:
            uptime = float((self.root / "proc/uptime").read_text().split()[0])
        except (OSError, ValueError, IndexError):
            return False
        # Installed by an updater from before starts were recorded: by the clock, as before.
        return record.get("at", 0) < time.time() - uptime

    # ── The three things this device can be asked to do ──
    def check(self):
        if self.root == Path("/"):          # Only the real device's clock.
            try:
                set_clock(self.root)
            except OSError:
                pass
        if not self.enrolled():
            return self.save(state="idle")
        held = self.lock(wait=False)
        if held is None:        # An install is running; it reports for itself.
            return self.status()
        try:
            return self.check_locked()
        finally:
            held.close()

    def check_locked(self):
        self.settle(recover=True, lock_held=True)
        if self.status().get("state") in BUSY:
            return self.status()
        try:
            self.fetch()
            manifest = self.latest()
        except (subprocess.SubprocessError, OSError, ValueError, KeyError, Stop) as error:
            message = str(error) if isinstance(error, Stop) else "Couldn’t reach the update server."
            self.save(lastChecked=int(time.time()), checkError=message)
            return self.tidy()
        offer = {key: manifest.get(key, "") for key in ("version", "notes", "date")}
        if not self.newer(manifest) or not self.ready_for_this_device(manifest):
            state = self.status().get("state")
            self.save(state="restart" if state == "restart" else "idle", available=None, lastChecked=int(time.time()),
                      checkError="")
            return self.tidy()
        known = self.status().get("available") or {}
        if known.get("version") == offer["version"] and "downloadBytes" in known:
            offer.update({key: known[key] for key in ("downloadBytes", "builds", "estimateSeconds") if key in known})
        else:
            offer.update(self.measure(manifest))
        self.notify(offer)
        self.save(state="available", available=offer, lastChecked=int(time.time()), checkError="", message="")
        return self.tidy()

    def tidy(self):
        """Once per installed version, after its restart: the old versions go (see clean_up)."""
        status = self.status()
        if status.get("installed") and status.get("cleanedFor") != status.get("installed") and status.get("state") not in BUSY:
            self.clean_up()
        return self.status()

    def install(self):
        current = self.installed()
        current_source = self.versions / current if current else None
        try:
            self.save(state="downloading", progress=5, message="Downloading…", started=int(time.time()))
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
        except Exception as error:      # Nothing on the device has changed yet, whatever went wrong.
            print("download failed: %r" % error, file=sys.stderr)
            reason = str(error) if isinstance(error, Stop) else "The update couldn’t be downloaded. Your device wasn’t changed."
            return self.save(state="error", message=reason, progress=0)
        try:
            self.save(state="installing", progress=75, message="Installing…")
            self.apply(source)
        except Exception as error:
            print("install failed: %r" % error, file=sys.stderr)
            self.save(state="restoring", progress=85, message="Putting the previous version back…")
            restored = False
            if current_source and current_source.is_dir():
                try:
                    self.apply(current_source)
                    restored = True
                except Exception as second:
                    print("restore failed: %r" % second, file=sys.stderr)
            return self.save(state="error", progress=0, repairTries=0, message="The update couldn’t be installed. "
                             + ("Your device is back on the previous version." if restored else "Restart your device."))
        self.record(manifest["version"], current)
        return self.save(state="restart", installed=manifest["version"], available=None, progress=100, repairTries=0,
                         message="Restart to finish updating.")

    def repair(self):
        """After an install or restore was cut off: the version installed.json names (the one that was working) is put
        back in full."""
        current = self.installed()
        source = self.versions / current if current else None
        if not source or not source.is_dir():
            # A device whose first version wasn't recorded: the only complete version it can get is the newest one.
            return self.install()
        try:
            self.save(state="installing", progress=40, message="Finishing an update that was interrupted…")
            self.apply(source)
        except Exception as error:
            print("repair failed: %r" % error, file=sys.stderr)
            return self.save(state="error", progress=0, message="An update was interrupted and couldn’t be finished. "
                             "Restart your device, then try again.")
        return self.save(state="restart", progress=100, repairTries=0,
                         message="An update was interrupted, so the version you had was put back. Restart to finish.")

    def restore(self):
        previous = self.previous()
        source = self.versions / previous if previous else None
        if not source or not source.is_dir():
            return self.save(state="error", message="There’s no earlier version on this device.", progress=0)
        current = self.installed()
        try:
            self.save(state="restoring", progress=40, message="Putting the previous version back…")
            self.apply(source)
        except Exception as error:
            print("restore failed: %r" % error, file=sys.stderr)
            return self.save(state="error", progress=0, message="The previous version couldn’t be restored.")
        write_atomic(self.state / "installed.json", json.dumps({"version": previous, "previous": "", "at": int(time.time()),
                                                               "boot": self.boot_id()}) + "\n")
        shutil.rmtree(self.versions / current, ignore_errors=True)
        return self.save(state="restart", installed=previous, progress=100, message="Restart to finish.")

    def job(self):
        held = self.lock()
        try:
            try:
                action = self.job_file.read_text().strip()
                self.job_file.unlink()
            except OSError:
                return self.status()
            work = {"restore": self.restore, "repair": self.repair}.get(action, self.install)
            try:
                return work()
            except Exception as error:      # Never left "busy": the next start would otherwise have to sort it out.
                print("%s failed: %r" % (action, error), file=sys.stderr)
                return self.save(state="error", progress=0, message="Something went wrong while updating. Restart your "
                                 "device, then try again.")
        finally:
            held.close()

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
        if self.status().get("state") in BUSY:
            return {"ok": True}
        write_atomic(self.job_file, action + "\n")
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
    elif command == "clock":
        print(json.dumps({"moved": round(set_clock())}))
    elif command == "settle":
        updater.settle_at_start()
    elif command == "job":
        updater.job()
    elif command == "status":
        print(json.dumps(updater.status(), indent=2, ensure_ascii=False))
    elif command == "selftest":
        # A new updater checks it can do its everyday work before it is kept: read the state, the device tools and the
        # release checks. Changes nothing.
        updater.status()
        tools = device_tools()
        assert callable(tools.Device("/").person) and callable(release.signature_valid) and callable(release.tree_digest)
        print("ok")
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
