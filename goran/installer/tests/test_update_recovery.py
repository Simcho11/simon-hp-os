"""hp-os-update never stays "busy" after an interruption, never runs two jobs at once, and keeps its files whole.

    python3 goran/installer/tests/test_update_recovery.py

Everything runs against a fake root folder: no real update state, Nix or systemd is touched.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SYSTEM = Path(__file__).resolve().parents[1] / "system"
sys.path.insert(0, str(SYSTEM))
loader = importlib.machinery.SourceFileLoader("hp_os_update", str(SYSTEM / "hp-os-update.py"))
spec = importlib.util.spec_from_loader("hp_os_update", loader)
update = importlib.util.module_from_spec(spec)
loader.exec_module(update)


class FakeRoot(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        (self.root / "proc/sys/kernel/random").mkdir(parents=True)
        (self.root / "proc/sys/kernel/random/boot_id").write_text("boot-2\n")
        self.updater = update.Updater(self.root)
        self.updater.state.mkdir(parents=True)
        self.applied = []
        self.updater.apply = lambda source: self.applied.append(Path(source).name)

    def state(self):
        return json.loads(self.updater.status_file.read_text())

    def set_state(self, **values):
        self.updater.save(**values)

    def install_version(self, version, previous=""):
        (self.updater.versions / version).mkdir(parents=True, exist_ok=True)
        (self.updater.state / "installed.json").write_text(json.dumps({"version": version, "previous": previous,
                                                                        "boot": "boot-1", "at": 1}))


class Recovery(FakeRoot):
    def test_cut_off_download_changed_nothing(self):
        self.set_state(state="downloading", progress=20)
        status = self.updater.settle(recover=True, lock_held=True)
        self.assertEqual(status["state"], "error")
        self.assertIn("before it changed anything", status["message"])
        self.assertFalse(self.updater.job_file.exists())

    def test_cut_off_install_puts_the_working_version_back(self):
        self.install_version("2026.11.20.1")
        self.set_state(state="installing", progress=75)
        status = self.updater.settle(recover=True, lock_held=True)
        self.assertEqual(status["state"], "installing")
        self.assertEqual(self.updater.job_file.read_text().strip(), "repair")
        status = self.updater.job()
        self.assertEqual(self.applied, ["2026.11.20.1"])
        self.assertEqual(status["state"], "restart")
        self.assertEqual(status["repairTries"], 0)

    def test_repeated_cut_offs_stop_after_two_tries(self):
        self.install_version("2026.11.20.1")
        for expected in (1, 2):
            self.set_state(state="installing")
            self.assertEqual(self.updater.settle(recover=True, lock_held=True)["repairTries"], expected)
        self.set_state(state="restoring")
        status = self.updater.settle(recover=True, lock_held=True)
        self.assertEqual(status["state"], "error")
        self.assertEqual(status["repairTries"], 0)

    def test_settings_asking_for_the_state_never_recovers(self):
        self.set_state(state="installing")
        self.assertEqual(self.updater.settle()["state"], "installing")
        self.assertFalse(self.updater.job_file.exists())

    def test_a_running_job_is_left_alone(self):
        self.set_state(state="installing")
        held = self.updater.lock()
        try:
            self.assertEqual(self.updater.settle_at_start()["state"], "installing")
        finally:
            held.close()
        self.assertFalse(self.updater.job_file.exists())

    def test_settle_at_start_recovers_when_nothing_runs(self):
        self.set_state(state="downloading")
        self.assertEqual(self.updater.settle_at_start()["state"], "error")

    def test_restart_is_finished_after_the_restart(self):
        self.install_version("2026.11.20.1")
        self.set_state(state="restart")
        self.assertEqual(self.updater.settle()["state"], "idle")


class Jobs(FakeRoot):
    def test_an_unexpected_error_never_leaves_the_job_busy(self):
        self.updater.job_file.write_text("install\n")
        def broken():
            self.updater.save(state="installing")
            raise TypeError("a bug")
        self.updater.install = broken
        status = self.updater.job()
        self.assertEqual(status["state"], "error")

    def test_a_failing_install_is_rolled_back_whatever_the_error(self):
        self.install_version("2026.11.20.1")
        new = self.updater.versions / "2026.11.21.1"
        calls = []
        def apply(source):
            calls.append(Path(source).name)
            if Path(source) == new:
                raise TypeError("not a RuntimeError")
        self.updater.apply = apply
        self.updater.ready_to_install = lambda: None
        self.updater.fetch = lambda: None
        self.updater.latest = lambda: {"version": "2026.11.21.1", "commit": "x", "digest": "y"}
        self.updater.unpack = lambda manifest: new.mkdir(parents=True) or new
        self.updater.use_ready_built = lambda manifest: False
        self.updater.build = lambda source: None
        status = self.updater.install()
        self.assertEqual(calls, ["2026.11.21.1", "2026.11.20.1"])
        self.assertEqual(status["state"], "error")
        self.assertIn("back on the previous version", status["message"])
        self.assertEqual(self.updater.installed(), "2026.11.20.1")

    def test_a_download_error_of_any_kind_changes_nothing(self):
        self.updater.ready_to_install = lambda: None
        def fetch():
            raise RuntimeError("unexpected")
        self.updater.fetch = fetch
        status = self.updater.install()
        self.assertEqual(status["state"], "error")
        self.assertEqual(self.applied, [])

    def test_repair_without_a_recorded_version_installs_the_newest(self):
        self.updater.install = lambda: self.updater.save(state="restart", installed="new")
        self.updater.job_file.write_text("repair\n")
        self.assertEqual(self.updater.job()["installed"], "new")

    def test_check_waits_for_nothing_while_a_job_runs(self):
        (self.updater.config_dir).mkdir(parents=True)
        (self.updater.config_dir / "config.json").write_text("{}")
        self.updater.signers.write_text("x")
        def fetch():
            raise AssertionError("a check must not fetch while a job runs")
        self.updater.fetch = fetch
        held = self.updater.lock()
        try:
            self.updater.check()
        finally:
            held.close()


class Files(FakeRoot):
    def test_write_atomic_leaves_the_whole_file_and_no_leftovers(self):
        target = self.root / "etc/nix/nix.conf"
        update.write_atomic(target, "one\n")
        update.write_atomic(target, "two\n", mode=0o600)
        self.assertEqual(target.read_text(), "two\n")
        self.assertEqual(oct(target.stat().st_mode & 0o777), "0o600")
        self.assertEqual(sorted(p.name for p in target.parent.iterdir()), ["nix.conf"])

    def test_an_unreadable_download_is_a_clear_stop(self):
        class Garbage:
            def __init__(self, *args, **kwargs):
                self.stdout = io.BytesIO(b"this is not a tar file" * 100)
            def kill(self):
                pass
            def wait(self):
                return 0
        real = update.subprocess.Popen
        update.subprocess.Popen = Garbage
        try:
            with self.assertRaises(update.Stop):
                self.updater.unpack({"version": "2026.11.21.1", "commit": "x", "digest": "y"})
        finally:
            update.subprocess.Popen = real
        self.assertFalse((self.updater.versions / "2026.11.21.1").exists())

    def test_the_old_version_folders_go_when_a_version_is_recorded(self):
        for version in ("a", "b", "c"):
            (self.updater.versions / version).mkdir(parents=True)
        self.updater.record("c", "b")
        self.assertEqual(sorted(p.name for p in self.updater.versions.iterdir()), ["b", "c"])


class Power(FakeRoot):
    def supply(self, name, kind, online=None, capacity=None):
        path = self.root / "sys/class/power_supply" / name
        path.mkdir(parents=True)
        (path / "type").write_text(kind + "\n")
        if online is not None:
            (path / "online").write_text("%d\n" % online)
        if capacity is not None:
            (path / "capacity").write_text("%d\n" % capacity)

    def supplies(self):
        return self.root / "sys/class/power_supply"

    def test_arm_charger(self):
        self.supply("ADP1", "Mains", online=1)
        self.assertTrue(self.updater.on_power(self.supplies()))

    def test_intel_charger_named_ac(self):
        self.supply("AC", "Mains", online=1)
        self.supply("BAT0", "Battery", capacity=10)
        self.assertTrue(self.updater.on_power(self.supplies()))

    def test_usb_c_charger(self):
        self.supply("ucsi-source-psy-USBC000:001", "USB", online=1)
        self.assertTrue(self.updater.on_power(self.supplies()))

    def test_unplugged(self):
        self.supply("AC", "Mains", online=0)
        self.supply("BAT0", "Battery", capacity=80)
        self.assertFalse(self.updater.on_power(self.supplies()))

    def test_low_battery_unplugged_is_refused(self):
        self.supply("AC", "Mains", online=0)
        self.supply("BAT0", "Battery", capacity=10)
        self.updater.free_gb = lambda: 100
        with self.assertRaises(update.Stop):
            self.updater.ready_to_install()

    def test_low_battery_plugged_in_is_fine(self):
        self.supply("AC", "Mains", online=1)
        self.supply("BAT0", "Battery", capacity=10)
        self.updater.free_gb = lambda: 100
        self.updater.ready_to_install()

    def test_a_battery_without_capacity_is_skipped(self):
        self.supply("BAT0", "Battery")
        self.updater.free_gb = lambda: 100
        self.updater.ready_to_install()


class OldVersions(FakeRoot):
    def test_only_the_device_profiles_not_their_versions(self):
        folder = self.root / "nix/var/nix/profiles"
        folder.mkdir(parents=True)
        for name in ("hp-os-add-user", "hp-os-add-user-3-link", "hp-os-accounts", "hp-os-accounts-12-link", "default"):
            (folder / name).symlink_to("/nix/store/x")
        self.assertEqual([p.name for p in self.updater.profiles()], ["hp-os-accounts", "hp-os-add-user"])

    def test_clean_up_never_runs_on_a_fake_root(self):
        self.assertFalse(self.updater.clean_up())

    def test_low_storage_tries_a_clean_up_first(self):
        cleaned = []
        sizes = iter([5, 50])
        self.updater.free_gb = lambda: next(sizes)
        self.updater.clean_up = lambda: cleaned.append(True)
        self.updater.ready_to_install()
        self.assertEqual(cleaned, [True])


class SelfTest(unittest.TestCase):
    def test_an_installed_updater_passes_its_own_check(self):
        with tempfile.TemporaryDirectory() as folder:
            shutil.copy(SYSTEM / "hp-os-update.py", Path(folder, "hp-os-update"))
            shutil.copy(SYSTEM / "hp-os-device.py", Path(folder, "hp-os-device"))
            shutil.copy(SYSTEM / "hp_os_release.py", Path(folder, "hp_os_release.py"))
            result = subprocess.run([sys.executable, "-I", str(Path(folder, "hp-os-update")), "selftest"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "ok")

    def test_a_broken_updater_fails_its_check(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "hp-os-update").write_text("import sys\nsys.exit(3)\n")
            result = subprocess.run([sys.executable, "-I", str(Path(folder, "hp-os-update")), "selftest"], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
