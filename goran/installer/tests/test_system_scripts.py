"""The update's system scripts: graphics drivers kept in step on Intel, and the system parts script's lists.

    python3 goran/installer/tests/test_system_scripts.py

Runs against fake root folders; nothing real is changed.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SYSTEM = Path(__file__).resolve().parents[1] / "system"
USB = Path(__file__).resolve().parents[1] / "usb"
OLD = "/nix/store/" + "a" * 32 + "-non-nixos-gpu"
NEW = "/nix/store/" + "b" * 32 + "-non-nixos-gpu"


class GraphicsDrivers(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        (self.root / "etc/tmpfiles.d").mkdir(parents=True)
        (self.root / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\nana:x:1001:1001::/home/ana:/bin/bash\n")
        for store in (OLD, NEW):
            self.drivers(store)
        os.symlink(OLD + "/lib/tmpfiles.d/non-nixos-gpu.conf", self.root / "etc/tmpfiles.d/non-nixos-gpu.conf")

    def drivers(self, store, complete=True):
        folder = self.root / store.lstrip("/")
        (folder / "lib/tmpfiles.d").mkdir(parents=True, exist_ok=True)
        (folder / "lib/tmpfiles.d/non-nixos-gpu.conf").write_text("L+ /run/opengl-driver - - - - %s\n" % store)
        if complete:
            (folder / "lib/libEGL_mesa.so.0").write_text("")

    def account_uses(self, store):
        setup = self.root / "home/ana/.local/state/nix/profiles/home-manager/home-path/bin/non-nixos-gpu-setup"
        setup.parent.mkdir(parents=True, exist_ok=True)
        setup.write_text("#!/bin/sh\nln -sf %s/lib/tmpfiles.d/non-nixos-gpu.conf /etc/tmpfiles.d/\n" % store)

    def run_script(self, machine="x86_64"):
        environment = dict(os.environ, HP_OS_TEST_ROOT=str(self.root), HP_OS_TEST_MACHINE=machine)
        return subprocess.run(["bash", str(SYSTEM / "hp-os-graphics-drivers.sh")], env=environment,
                              capture_output=True, text=True)

    def link(self):
        return os.readlink(self.root / "etc/tmpfiles.d/non-nixos-gpu.conf")

    def test_points_at_the_desktops_new_drivers_and_keeps_the_old_ones(self):
        self.account_uses(NEW)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.link(), NEW + "/lib/tmpfiles.d/non-nixos-gpu.conf")
        self.assertEqual(os.readlink(self.root / "nix/var/nix/gcroots/hp-os-graphics-previous"),
                         OLD + "/lib/tmpfiles.d/non-nixos-gpu.conf")

    def test_arm_is_left_alone(self):
        self.account_uses(NEW)
        self.run_script(machine="aarch64")
        self.assertEqual(self.link(), OLD + "/lib/tmpfiles.d/non-nixos-gpu.conf")

    def test_incomplete_drivers_are_not_used(self):
        incomplete = "/nix/store/" + "c" * 32 + "-non-nixos-gpu"
        self.drivers(incomplete, complete=False)
        self.account_uses(incomplete)
        result = self.run_script()
        self.assertEqual(result.returncode, 0)
        self.assertIn("incomplete", result.stderr)
        self.assertEqual(self.link(), OLD + "/lib/tmpfiles.d/non-nixos-gpu.conf")

    def test_nothing_to_do_when_unchanged_or_unknown(self):
        self.account_uses(OLD)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.link(), OLD + "/lib/tmpfiles.d/non-nixos-gpu.conf")
        os.unlink(self.root / "etc/tmpfiles.d/non-nixos-gpu.conf")
        (self.root / "etc/tmpfiles.d/non-nixos-gpu.conf").write_text("not a link\n")
        self.account_uses(NEW)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual((self.root / "etc/tmpfiles.d/non-nixos-gpu.conf").read_text(), "not a link\n")


class Packages(unittest.TestCase):
    def script_packages(self):
        text = (SYSTEM / "hp-os-system-packages.sh").read_text()
        block = re.search(r"^packages=\((.*?)^\)", text, re.S | re.M).group(1)
        return {word for line in block.splitlines() for word in line.split("#")[0].split()}

    def image_packages(self):
        text = (USB / "x86/base-packages.txt").read_text()
        return {word for line in text.splitlines() if not line.startswith("#") for word in line.split()}

    def test_every_backfilled_package_is_also_in_new_installs(self):
        self.assertEqual(self.script_packages() - self.image_packages(), set())

    def test_printing_is_there(self):
        for package in ("cups", "cups-browsed", "cups-filters", "ipp-usb", "avahi-daemon", "libnss-mdns", "hplip",
                        "printer-driver-hpcups"):
            self.assertIn(package, self.script_packages())

    def test_scripts_parse(self):
        for name in ("hp-os-system-packages.sh", "hp-os-graphics-drivers.sh", "hp-os-add-user.sh", "hp-os-login-session.sh",
                     "hp-os-login-theme.sh", "hp-os-device-setup.sh"):
            self.assertEqual(subprocess.run(["bash", "-n", str(SYSTEM / name)]).returncode, 0, name)

    def test_the_update_runs_both_scripts_and_never_fails_on_them(self):
        text = (SYSTEM / "hp-os-add-user.sh").read_text()
        self.assertIn('"$here/hp-os-system-packages.sh" || true', text)
        self.assertIn('"$here/hp-os-graphics-drivers.sh" || true', text)


if __name__ == "__main__":
    unittest.main()
