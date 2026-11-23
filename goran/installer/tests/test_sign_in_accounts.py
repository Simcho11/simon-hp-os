"""Sign-in and accounts: the root helpers (recovery key, device, app installer), the HP-OS session started at sign-in and
first-login setup's outcome, all against fake roots and fake commands. Nothing here touches the live system.

Run with the system Python (it has libcrypt): /usr/bin/python3 -m unittest goran/installer/tests/test_sign_in_accounts.py
"""
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

SYSTEM = Path(__file__).resolve().parents[1] / "system"
INSTALLER = Path(__file__).resolve().parents[1]


def load(name, path):
    loader = SourceFileLoader(name, str(path))
    module = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


recovery = load("hp_os_recovery", SYSTEM / "hp-os-recovery.py")
device = load("hp_os_device", SYSTEM / "hp-os-device.py")
app_install = load("hp_os_app_install", SYSTEM / "hp-os-app-install.py")

ME = os.getuid()


def person(name, uid, home=None):
    return pwd.struct_passwd((name, "x", uid, uid, name, home or "/home/" + name, "/bin/bash"))


class Done:
    def __init__(self, returncode=0, stdout=""):
        self.returncode, self.stdout = returncode, stdout


class FakeRecovery(recovery.Recovery):
    """People and administrators come from the test, not from this laptop's accounts."""
    def __init__(self, root, people, admins, clock):
        self.people, self.admins, self.commands = people, admins, []
        super().__init__(root, run=self.fake_run, now=lambda: clock[0], pause=lambda seconds: None)

    def fake_run(self, command, data=None):
        self.commands.append(command)
        return Done(0, json.dumps({"blockdevices": []}))

    def person(self, name):
        return self.people.get(name)

    def uid_person(self, uid):
        return next((who for who in self.people.values() if who.pw_uid == uid), None)

    def is_admin(self, who):
        return who.pw_name in self.admins

    @staticmethod
    def login_screen():
        return 990


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.clock = [1_800_000_000.0]
        # "ann" is this test's own uid, so her (fake) home can belong to her.
        self.people = {"ann": person("ann", ME), "bob": person("bob", 50001), "cat": person("cat", 50002)}
        self.helper = FakeRecovery(self.root, self.people, {"bob"}, self.clock)
        self.key = self.helper.new()["key"]

    def tries(self):
        return json.loads((self.root / "var/lib/hp-os/recovery-tries").read_text())

    def test_lockout_never_longer_than_a_day_after_the_clock_goes_back(self):
        for _ in range(recovery.FREE_TRIES + 12):
            self.helper.failed()
        self.assertEqual(self.helper.wait_left(), 86400)
        self.clock[0] -= 30 * 86400          # the clock jumps a month back
        self.assertEqual(self.helper.wait_left(), 86400)
        self.clock[0] += 31 * 86400          # and comes back
        self.assertEqual(self.helper.wait_left(), 0)
        # A damaged record never locks anyone out for good.
        (self.root / "var/lib/hp-os/recovery-tries").write_text('{"failed": 9, "until": 1e999}\n')
        self.assertEqual(self.helper.wait_left(), 0)

    def test_save_usb_only_for_the_login_screen_root_or_an_administrator(self):
        refused = self.helper.answer(50002, {"action": "save-usb", "key": self.key})
        self.assertFalse(refused["ok"])
        self.assertIn("administrator", refused["error"])
        for uid in (0, 990, 50001):
            answer = self.helper.answer(uid, {"action": "save-usb", "key": self.key})
            self.assertEqual(answer["error"], "Plug in a USB stick, then try again.")   # the key was right

    def test_save_usb_counts_wrong_keys_with_reset(self):
        for count in range(1, recovery.FREE_TRIES + 1):
            answer = self.helper.answer(990, {"action": "save-usb", "key": "WRONG" * 5})
            self.assertFalse(answer["ok"])
            self.assertEqual(self.tries()["failed"], count)
        answer = self.helper.answer(990, {"action": "save-usb", "key": "WRONG" * 5})
        self.assertIn("Too many tries", answer["error"])
        # Locked out for a reset too, even with the right key.
        answer = self.helper.answer(990, {"action": "reset", "user": "cat", "key": self.key, "password": "newpassword"})
        self.assertIn("Too many tries", answer["error"])
        self.clock[0] += 3600
        answer = self.helper.answer(50001, {"action": "save-usb", "key": self.key})
        self.assertEqual(answer["error"], "Plug in a USB stick, then try again.")
        self.assertFalse((self.root / "var/lib/hp-os/recovery-tries").exists())

    def make_keyring(self, name="ann"):
        folder = self.root / "home" / name / ".local/share/keyrings"
        folder.mkdir(parents=True)
        (folder / "login.keyring").write_text("old")
        return folder

    def test_reset_puts_the_login_keyring_aside(self):
        folder = self.make_keyring()
        answer = self.helper.answer(990, {"action": "reset", "user": "ann", "key": self.key, "password": "newpassword"})
        self.assertEqual(answer, {"ok": True, "keyring": "moved"})
        self.assertTrue(any(command[0] == "/usr/sbin/chpasswd" for command in self.helper.commands))
        self.assertFalse((folder / "login.keyring").exists())
        day = time.strftime("%Y-%m-%d", time.localtime(self.clock[0]))
        self.assertEqual((folder / ("login.keyring.before-reset-" + day)).read_text(), "old")
        # A second reset the same day keeps the first one's copy.
        (folder / "login.keyring").write_text("newer")
        self.assertEqual(self.helper.keyring_aside(self.people["ann"]), "moved")
        self.assertEqual((folder / ("login.keyring.before-reset-%s-2" % day)).read_text(), "newer")
        self.assertEqual(self.helper.keyring_aside(self.people["ann"]), "none")

    def test_keyring_aside_never_follows_links(self):
        outside = self.root / "elsewhere/share/keyrings"
        outside.mkdir(parents=True)
        (outside / "login.keyring").write_text("not hers")
        (self.root / "home/ann").mkdir(parents=True)
        os.symlink(self.root / "elsewhere", self.root / "home/ann/.local")
        self.assertEqual(self.helper.keyring_aside(self.people["ann"]), "kept")
        self.assertTrue((outside / "login.keyring").exists())
        os.unlink(self.root / "home/ann/.local")
        folder = self.root / "home/ann/.local/share/keyrings"
        folder.mkdir(parents=True)
        os.symlink(outside / "login.keyring", folder / "login.keyring")
        self.assertEqual(self.helper.keyring_aside(self.people["ann"]), "kept")
        self.assertTrue(os.path.islink(folder / "login.keyring"))

    def test_keyring_aside_only_in_the_persons_own_folders(self):
        self.make_keyring("bob")          # made by this test's uid, so not bob's
        self.assertEqual(self.helper.keyring_aside(self.people["bob"]), "kept")
        self.assertEqual(self.helper.keyring_aside(person("ann", ME, "/srv/ann")), "kept")

    def test_keyring_aside_request_from_settings(self):
        self.make_keyring()
        self.assertFalse(self.helper.answer(50002, {"action": "keyring-aside", "user": "ann"})["ok"])
        self.assertFalse(self.helper.answer(50001, {"action": "keyring-aside", "user": "bob"})["ok"])   # not their own
        self.assertEqual(self.helper.answer(50001, {"action": "keyring-aside", "user": "ann"}), {"ok": True, "keyring": "moved"})


class DeviceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "etc").mkdir()
        (self.root / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\n"
                                              "ann:x:1000:1000::/home/ann:/bin/bash\n"
                                              "bob:x:1001:1001::/home/bob:/bin/bash\n")
        (self.root / "etc/group").write_text("sudo:x:27:ann\nann:x:1000:\nbob:x:1001:\n")
        (self.root / "etc/shadow").write_text("")
        (self.root / "etc/machine-id").write_text("0123456789abcdef0123456789abcdef\n")
        self.failing = set()
        self.commands = []
        self.device = device.Device(self.root, run=self.fake_run)

    def fake_run(self, command):
        self.commands.append(command)
        if command[0] == "/usr/sbin/userdel" and command[-1] not in self.failing:
            lines = (self.root / "etc/passwd").read_text().splitlines(keepends=True)
            (self.root / "etc/passwd").write_text("".join(l for l in lines if not l.startswith(command[-1] + ":")))
            (self.root / "etc/group").write_text((self.root / "etc/group").read_text().replace(command[-1], "gone"))

    def test_setup_note_only_about_your_own_account_and_from_fixed_text(self):
        notes = self.root / "var/lib/hp-os/setup-notes"
        self.assertEqual(self.device.answer(1001, {"action": "setup-note", "reason": "network"}), {"ok": True})
        self.assertEqual((notes / "bob.qml").read_text(), 'import QtQuick 2.15\nItem { readonly property string reason: "network" }\n')
        self.assertEqual(oct((notes / "bob.qml").stat().st_mode & 0o777), "0o644")
        self.assertFalse(self.device.answer(1001, {"action": "setup-note", "reason": '"}\nItem { x: 1'})["ok"])
        self.assertFalse(self.device.answer(4242, {"action": "setup-note", "reason": "other"})["ok"])
        self.assertEqual(self.device.answer(1001, {"action": "setup-note", "reason": ""}), {"ok": True})
        self.assertFalse((notes / "bob.qml").exists())
        self.assertEqual(sorted(os.listdir(notes)), [])

    def test_forget_account_only_after_it_is_gone(self):
        items = ["var/lib/hp-os/login-wallpapers/cat.jpg", "var/lib/hp-os/login-wallpapers/default.jpg", "var/lib/hp-os/setup-notes/cat.qml",
                 "nix/var/nix/profiles/per-user/cat/profile", "nix/var/nix/gcroots/per-user/cat/x",
                 "var/lib/systemd/linger/cat", "var/lib/hp-os/login-wallpapers/bob.jpg"]
        for item in items:
            (self.root / item).parent.mkdir(parents=True, exist_ok=True)
            (self.root / item).write_text("x")
        (self.root / "var/lib/sddm").mkdir(parents=True)
        (self.root / "var/lib/sddm/state.conf").write_text("[Last]\n# Name of the last user\nUser=cat\n\nSession=hpos.desktop\n")
        self.assertFalse(self.device.answer(1000, {"action": "forget-account", "user": "bob"})["ok"])
        self.assertFalse(self.device.answer(1000, {"action": "forget-account", "user": "../etc"})["ok"])
        answer = self.device.answer(1001, {"action": "forget-account", "user": "cat"})
        self.assertTrue(answer["ok"])
        for item in items[:-1]:
            self.assertFalse(os.path.lexists(self.root / item), item)
        self.assertFalse(os.path.lexists(self.root / "nix/var/nix/profiles/per-user/cat"))
        self.assertTrue((self.root / "var/lib/hp-os/login-wallpapers/bob.jpg").exists())
        self.assertEqual((self.root / "var/lib/sddm/state.conf").read_text(),
                         "[Last]\n# Name of the last user\n\nSession=hpos.desktop\n")

    def test_forget_account_keeps_someone_elses_owner_picture(self):
        pictures = self.root / "var/lib/hp-os/login-wallpapers"
        pictures.mkdir(parents=True)
        (pictures / "cat.jpg").write_text("cat's")
        (pictures / "default.jpg").write_text("ann's")
        self.assertTrue(self.device.answer(1001, {"action": "forget-account", "user": "cat"})["ok"])
        self.assertEqual(sorted(os.listdir(pictures)), ["default.jpg"])

    def test_factory_reset_lists_each_accounts_own_items(self):
        (self.root / "var/lib/hp-os/login-wallpapers").mkdir(parents=True)
        (self.root / "nix/var/nix/profiles/per-user/ann").mkdir(parents=True)
        plan = self.device.plan()
        self.assertIn("/nix/var/nix/profiles/per-user/ann", plan["other data"])

    def request_reset(self):
        self.device.write_private(self.device.request, json.dumps({"machine": self.device.machine_id()}), 0o600)
        for name in ("ann", "bob"):
            (self.root / "home" / name).mkdir(parents=True)

    def test_reset_marks_first_time_setup_once_no_administrator_is_left(self):
        self.request_reset()
        self.failing = {"bob"}          # a standard account that won't go
        self.assertIn("some accounts remain", self.device.wipe())
        self.assertTrue(self.device.first_boot.exists())
        self.assertTrue(self.device.request.exists())
        self.failing = set()
        self.assertEqual(self.device.wipe(), "erased")
        self.assertTrue(self.device.first_boot.exists())
        self.assertFalse(self.device.request.exists())

    def test_reset_leaves_the_login_screen_usable_while_an_administrator_remains(self):
        self.request_reset()
        self.device.write_private(self.device.first_boot, device.FIRST_BOOT_MARK, 0o644)   # from an older reset
        self.failing = {"ann"}          # the administrator
        self.assertIn("some accounts remain", self.device.wipe())
        self.assertFalse(self.device.first_boot.exists())
        self.assertTrue(self.device.request.exists())


class AppInstallTest(unittest.TestCase):
    def setUp(self):
        if not shutil.which("dpkg-deb"):
            self.skipTest("dpkg-deb isn't installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.installer = app_install.Installer(self.root / "state", self.root / "icons")

    def deb(self, name, files=(), postinst=None):
        tree = self.root / ("tree-" + name)
        (tree / "DEBIAN").mkdir(parents=True)
        (tree / "DEBIAN/control").write_text("Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: Someone <a@b.c>\n"
                                             "Description: A test app\n just a test\n" % name)
        if postinst:
            (tree / "DEBIAN/postinst").write_text(postinst)
            os.chmod(tree / "DEBIAN/postinst", 0o755)
        for path in files:
            (tree / path.lstrip("/")).parent.mkdir(parents=True, exist_ok=True)
            (tree / path.lstrip("/")).write_text("x\n")
        built = self.root / (name + ".deb")
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(tree), str(built)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return built

    def describe(self, built):
        with open(built, "rb") as stream:
            token = self.installer.take(stream.fileno())
        return self.installer.describe(token)

    def test_a_plain_app_adds_no_source(self):
        info = self.describe(self.deb("hp-os-test-plain", ["/usr/share/doc/hp-os-test-plain/README"]))
        self.assertTrue(info["ok"])
        self.assertFalse(info["addsSource"])
        self.assertEqual(info["publisher"], "Someone")

    def test_a_source_or_key_in_the_files_is_noticed(self):
        for path in ("/etc/apt/sources.list.d/vendor.list", "/usr/share/keyrings/vendor.gpg", "/etc/apt/trusted.gpg.d/v.gpg"):
            name = "hp-os-test-" + re.sub(r"[^a-z]", "", path)[-12:]
            self.assertTrue(self.describe(self.deb(name, [path]))["addsSource"], path)

    def test_a_source_added_by_the_install_script_is_noticed(self):
        script = "#!/bin/sh\necho 'deb https://example.com stable main' > /etc/apt/sources.list.d/example.list\n"
        self.assertTrue(self.describe(self.deb("hp-os-test-script", postinst=script))["addsSource"])

    def test_where_the_file_came_from(self):
        target = self.root / "download.deb"
        target.write_bytes(b"x")
        with open(target, "rb") as stream:
            self.assertEqual(self.installer.origin(stream.fileno()), "")
            for noted, shown in (("https://www.example.com/app.deb", "example.com"), ("http://dl.vendor.io/x", "dl.vendor.io"),
                                 ("file:///etc/passwd", ""), ("https://exa mple.com/", ""), ("javascript:alert(1)", "")):
                try:
                    os.setxattr(target, "user.xdg.origin.url", noted.encode())
                except OSError:
                    self.skipTest("this file system keeps no user attributes")
                self.assertEqual(self.installer.origin(stream.fileno()), shown, noted)


class SessionTest(unittest.TestCase):
    """The session script SDDM starts, cut out of hp-os-login-session.sh, with its absolute paths moved into a fake root."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        text = (SYSTEM / "hp-os-login-session.sh").read_text()
        script = text.split("cat > \"$target.new\" <<'EOF'\n", 1)[1].split("\nEOF\n", 1)[0] + "\n"
        # A socket's path has to be short: the helper's socket is found from the folder the session runs in.
        script = script.replace('"/run/hp-os/factory-reset.sock"', '"factory-reset.sock"')
        for real in ("/nix/var/nix/profiles/", "/opt/hp-os/", "/run/hp-os/", "/var/lib/hp-os/", "/usr/bin/systemctl",
                     "/usr/bin/loginctl", "/usr/bin/gdbus"):
            script = script.replace(real, str(self.root) + real)
        self.session = self.root / "session"
        self.session.write_text(script)
        self.home = self.root / "home"
        self.log = self.root / "log"
        self.bin = self.root / "bin"
        for folder in (self.home, self.bin, self.root / "run/hp-os", self.root / "opt/hp-os/login",
                       self.root / "opt/hp-os/device", self.root / "usr/bin"):
            folder.mkdir(parents=True, exist_ok=True)
        self.fake(self.root / "opt/hp-os/login/initialize-profile.py", "", python=True)
        self.fake(self.root / "usr/bin/systemctl", "echo running")
        self.fake(self.root / "usr/bin/loginctl", "exit 0")
        self.fake(self.root / "usr/bin/gdbus", "exit 0")
        self.fake(self.bin / "logger", 'echo "logger $*" >> "%s"' % self.log)
        self.fake(self.bin / "loginctl", "exit 0")
        self.notes = []
        self.server = socket.socket(socket.AF_UNIX)
        here = os.getcwd()
        os.chdir(self.root / "run/hp-os")
        try:
            self.server.bind("factory-reset.sock")
        finally:
            os.chdir(here)
        self.server.listen(4)
        self.addCleanup(self.server.close)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                self.notes.append(json.loads(connection.makefile().readline()))
                connection.sendall(b'{"ok": true}\n')

    def fake(self, path, body, python=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(("#!/usr/bin/python3\n" if python else "#!/bin/bash\n") + body + "\n")
        os.chmod(path, 0o755)

    def account_setup(self, result, ready_after=True):
        """A fake hp-os-account-setup: --needed until it succeeded; a real run records its outcome like the real one."""
        state = self.home / ".local/state/hp-os/enrollment"
        self.fake(self.root / "nix/var/nix/profiles/hp-os-accounts/bin/hp-os-account-setup", """
state=%s
mkdir -p "$state"
if [[ ${1:-} == --needed ]]; then [[ -e "$state/ready" ]] && exit 1; exit 0; fi
echo "setup run" >> %s
[[ -e "$state/ready" ]] && exit 0
printf 'running\\n' > "$state/outcome"
if [[ %s == ok ]]; then printf 'ok\\n' > "$state/outcome"; %s exit 0; fi
printf 'failed %s\\n' > "$state/outcome"; exit 1
""" % (state, self.log, result, 'touch "$state/ready";' if ready_after else "", result))

    def screen(self, runs_setup=True):
        self.fake(self.root / "nix/var/nix/profiles/hp-os-add-user/bin/hp-os-first-setup",
                  'echo "screen" >> %s\n%s' % (self.log, '"%s/nix/var/nix/profiles/hp-os-accounts/bin/hp-os-account-setup"'
                                                % self.root if runs_setup else "exit 0"))

    def desktop(self, works=True):
        own = self.home / ".local/state/nix/profiles/home-manager/home-path/bin"
        if works:
            self.fake(own / "hp-os-session", 'echo "desktop" >> %s' % self.log)

    def run_session(self):
        environment = {"HOME": str(self.home), "USER": "ann", "PATH": "%s:/usr/bin:/bin" % self.bin,
                       "XDG_SESSION_ID": "7"}
        started = time.monotonic()
        done = subprocess.run(["/bin/bash", str(self.session)], env=environment, capture_output=True, text=True, timeout=60,
                              cwd=self.root / "run/hp-os")
        took = time.monotonic() - started
        self.assertEqual(done.returncode, 0, done.stderr)
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return lines, took

    def test_failed_setup_after_the_screen_isnt_tried_again_and_leaves_a_note(self):
        self.account_setup("network")
        self.screen()
        lines, _ = self.run_session()
        self.assertEqual([line for line in lines if not line.startswith("logger")], ["screen", "setup run"])
        self.assertEqual(self.notes, [{"action": "setup-note", "reason": "network"}])
        self.assertTrue(any("first-login setup" in line for line in lines))

    def test_failed_setup_opens_the_desktop_the_account_already_has(self):
        self.account_setup("storage", ready_after=False)
        self.screen()
        self.desktop()
        lines, _ = self.run_session()
        self.assertEqual([line for line in lines if not line.startswith("logger")], ["screen", "setup run", "desktop"])
        self.assertEqual(self.notes, [])

    def test_a_screen_that_never_ran_the_setup_leaves_it_to_the_session(self):
        self.account_setup("ok")
        self.screen(runs_setup=False)
        self.desktop()
        lines, _ = self.run_session()
        self.assertEqual([line for line in lines if not line.startswith("logger")], ["screen", "setup run", "desktop"])

    def test_without_a_screen_the_setup_runs_once(self):
        self.account_setup("other")
        lines, _ = self.run_session()
        self.assertEqual([line for line in lines if not line.startswith("logger")], ["setup run"])
        self.assertEqual(self.notes, [{"action": "setup-note", "reason": "other"}])

    def test_the_note_goes_when_the_desktop_opens(self):
        self.account_setup("ok")
        self.desktop()
        notes = self.root / "var/lib/hp-os/setup-notes"
        notes.mkdir(parents=True)
        (notes / "ann.qml").write_text("x")
        lines, _ = self.run_session()
        self.assertIn("desktop", lines)
        self.assertEqual(self.notes, [{"action": "setup-note", "reason": ""}])

    def test_signing_out_never_waits_for_the_wallpaper(self):
        self.account_setup("ok")
        self.desktop()
        shared = self.root / "shared"
        # Converting a big picture: the session must be over long before this finishes.
        self.fake(self.root / "opt/hp-os/device/hp-os-login-wallpaper",
                  "import sys, time\nif sys.argv[1:] == ['share']:\n    time.sleep(4)\n    open(%r, 'a').write('shared\\n')"
                  % str(shared), python=True)
        lines, took = self.run_session()
        self.assertLess(took, 3)
        self.assertIn("desktop", lines)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not (shared.exists() and shared.read_text().count("shared") >= 2):
            time.sleep(0.2)
        self.assertEqual(shared.read_text().count("shared"), 2)       # at the start and at the end, both finished


class AccountSetupOutcomeTest(unittest.TestCase):
    """account-setup.sh records why an attempt failed. Only its outcome bookkeeping runs: nix is a fake that fails."""

    def run_setup(self, nix_says):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        fakes = root / "bin"
        fakes.mkdir()
        (fakes / "nix").write_text("#!/bin/bash\necho %r >&2\nexit 1\n" % nix_says)
        os.chmod(fakes / "nix", 0o755)
        script = (INSTALLER / "account-setup.sh").read_text().replace("export PATH=/usr/bin:/bin", "export PATH=%s:/usr/bin:/bin" % fakes)
        (root / "setup.sh").write_text(script)
        who = pwd.getpwuid(os.getuid())
        if who.pw_dir != "/home/" + who.pw_name:
            self.skipTest("needs an account with its home in /home")
        state = root / "state"
        environment = {"HOME": who.pw_dir, "USER": who.pw_name, "PATH": "/usr/bin:/bin", "XDG_STATE_HOME": str(state),
                       "HP_OS_PROFILE_FLAKE": "/nix/store/none", "HP_OS_SETUP_PROGRESS": "1"}
        done = subprocess.run(["/bin/bash", str(root / "setup.sh")], env=environment, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(subprocess.run(["/bin/bash", str(root / "setup.sh"), "--needed"], env=environment).returncode, 0)
        return (state / "hp-os/enrollment/outcome").read_text().strip()

    def test_reasons(self):
        free = shutil.disk_usage("/nix/store").free
        if free < 2 * 1024 ** 3 or shutil.disk_usage(pwd.getpwuid(os.getuid()).pw_dir).free < 2 * 1024 ** 3:
            self.skipTest("this laptop is low on space itself")
        self.assertEqual(self.run_setup("error: writing to file: No space left on device"), "failed storage")
        self.assertEqual(self.run_setup("error: unable to download 'https://x': Could not resolve host: x"), "failed network")
        self.assertEqual(self.run_setup("error: attribute 'x' missing"), "failed other")


if __name__ == "__main__":
    unittest.main()
