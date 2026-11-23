"""The scripts that adjust an account's ~/.config/hp-os/config.json during Home Manager updates and
at session start (files-dock-pin.py, dock-add-once.py, hp-os-battery.py, hp-snap/apply-defaults.py).

They run under `set -e`: one that fails on a damaged config.json stops every later update step, and
at session start the desktop itself. So a config.json that can't be read as HP-OS settings is left
byte for byte as it is, no marker is written (the change still goes in once the file is whole
again), and the script succeeds. Everything runs in a temporary HOME.

    python3 goran/desktop/test_config_scripts.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FILES_DOCK_PIN = HERE / "files-dock-pin.py"
DOCK_ADD_ONCE = HERE / "dock-add-once.py"
BATTERY = HERE / "hp-os-battery.py"
APPLY_DEFAULTS = HERE / "hp-snap/apply-defaults.py"

# Not HP-OS settings at all: every script leaves these alone.
DAMAGED = {
    "empty": b"",
    "cut short": b'{"dock": {"pinnedApps": ["org.kde.dolphin", "goo',
    "not text": b"\xff\xfe\x00{garbage",
    "a list": b'["org.kde.dolphin"]\n',
    "a string": b'"config"\n',
    "null": b"null\n",
}
# Settings in a shape the script can't work with: only the script that looks there leaves them alone.
ODD_SHAPES = {
    "dock not an object": (b'{"dock": ["org.kde.dolphin"]}\n', {"files-dock-pin.py", "dock-add-once.py"}),
    "pins not a list": (b'{"dock": {"pinnedApps": "org.kde.dolphin"}}\n', {"files-dock-pin.py", "dock-add-once.py"}),
    "pins null": (b'{"dock": {"pinnedApps": null}}\n', {"files-dock-pin.py"}),
    "iris not an object": (b'{"iris": "bar"}\n', {"hp-os-battery.py"}),
    "pieces not a list": (b'{"iris": {"bar": {"pieces": "sound"}}}\n', {"hp-os-battery.py"}),
    "audio not an object": (b'{"audio": 3}\n', {"hp-os-battery.py"}),
    "protection not an object": (b'{"audio": {"protection": [10]}}\n', {"hp-os-battery.py"}),
}


class ConfigScripts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "home"
        self.state = Path(self.tmp.name) / "state"
        self.folder = self.home / ".config/hp-os"
        self.folder.mkdir(parents=True)
        self.config = self.folder / "config.json"
        self.env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home),
                    "XDG_STATE_HOME": str(self.state)}
        self.defaults = Path(self.tmp.name) / "defaults.json"
        self.defaults.write_text(json.dumps({"dock": {"autoHide": True}, "bar": {"glass": "on"}}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, script, *args):
        return subprocess.run([sys.executable, "-I", str(script), *map(str, args)], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def runs(self):
        """Every script, the way Home Manager and the session start call it, with its marker."""
        return [
            (FILES_DOCK_PIN, [self.config], None),
            (DOCK_ADD_ONCE, [self.config, "google-chrome", "org.kde.dolphin", self.state / "dock-chrome-v1"],
             self.state / "dock-chrome-v1"),
            (BATTERY, [self.config], self.state / "hp-os/hp-os-battery-v1"),
            (APPLY_DEFAULTS, [self.defaults, self.config, self.state / "defaults-v1"], self.state / "defaults-v1"),
            (APPLY_DEFAULTS, [self.defaults, self.config], None),
        ]

    def assert_left_alone(self, script, args, marker, content):
        self.config.write_bytes(content)
        self.config.chmod(0o640)
        before = self.config.stat()
        result = self.run_script(script, *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("as it is", result.stderr)
        self.assertEqual(self.config.read_bytes(), content)
        after = self.config.stat()
        self.assertEqual((after.st_ino, after.st_mode, after.st_mtime_ns),
                         (before.st_ino, before.st_mode, before.st_mtime_ns))
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["config.json"])
        if marker is not None:
            # Unmarked, so the change still goes in once the file is whole again.
            self.assertFalse(marker.exists())

    def test_damaged_config_is_left_alone(self):
        for label, content in DAMAGED.items():
            for script, args, marker in self.runs():
                with self.subTest(script=script.name, config=label):
                    self.assert_left_alone(script, args, marker, content)

    def test_odd_settings_are_left_alone(self):
        for label, (content, scripts) in ODD_SHAPES.items():
            for script, args, marker in self.runs():
                if script.name in scripts:
                    with self.subTest(script=script.name, config=label):
                        self.assert_left_alone(script, args, marker, content)

    def test_unreadable_config_is_left_alone(self):
        # A folder where config.json should be: reading it fails like an unreadable file would.
        self.config.mkdir()
        for script, args, marker in self.runs():
            with self.subTest(script=script.name):
                result = self.run_script(script, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(self.config.is_dir())
                if marker is not None:
                    self.assertFalse(marker.exists())

    def test_whole_again_later(self):
        self.config.write_bytes(DAMAGED["cut short"])
        for script, args, marker in self.runs():
            self.run_script(script, *args)
        self.config.write_text(json.dumps({"dock": {"pinnedApps": ["com.system76.CosmicFiles"]}}))
        for script, args, marker in self.runs():
            result = self.run_script(script, *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            if marker is not None:
                self.assertTrue(marker.exists(), script.name)
        config = json.loads(self.config.read_text())
        self.assertEqual(config["dock"]["pinnedApps"], ["org.kde.dolphin", "google-chrome"])
        self.assertEqual(config["iris"]["bar"]["pieces"], ["sound", "battery", "notifications"])
        self.assertEqual(config["audio"]["protection"]["maxAllowedIncrease"], 11)
        self.assertEqual(config["dock"]["autoHide"], True)

    def test_files_pin(self):
        self.config.write_text(json.dumps({"dock": {"pinnedApps": [
            "com.system76.CosmicFiles.desktop", "firefox", "org.kde.dolphin"]}, "name": "é"}))
        self.assertEqual(self.run_script(FILES_DOCK_PIN, self.config).returncode, 0)
        self.assertEqual(self.config.read_text(), json.dumps(
            {"dock": {"pinnedApps": ["org.kde.dolphin", "firefox"]}, "name": "é"},
            indent=2, ensure_ascii=False) + "\n")

    def test_dock_add_once(self):
        marker = self.state / "dock-chrome-v1"
        self.config.write_text(json.dumps({"dock": {"pinnedApps": ["firefox", "org.kde.dolphin", "x"]}}))
        self.assertEqual(self.run_script(DOCK_ADD_ONCE, self.config, "google-chrome", "org.kde.dolphin",
                                         marker).returncode, 0)
        self.assertEqual(json.loads(self.config.read_text())["dock"]["pinnedApps"],
                         ["firefox", "org.kde.dolphin", "google-chrome", "x"])
        self.assertTrue(marker.exists())
        # Taken off the Dock later: it stays off.
        self.config.write_text(json.dumps({"dock": {"pinnedApps": ["firefox"]}}))
        self.run_script(DOCK_ADD_ONCE, self.config, "google-chrome", "org.kde.dolphin", marker)
        self.assertEqual(json.loads(self.config.read_text())["dock"]["pinnedApps"], ["firefox"])

    def test_dock_add_once_new_account(self):
        marker = self.state / "dock-chrome-v1"
        self.assertEqual(self.run_script(DOCK_ADD_ONCE, self.config, "google-chrome", "org.kde.dolphin",
                                         marker).returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertTrue(marker.exists())

    def test_battery_once(self):
        marker = self.state / "hp-os/hp-os-battery-v1"
        self.config.write_text(json.dumps({"iris": {"bar": {"pieces": ["sound"]}}}))
        self.assertEqual(self.run_script(BATTERY, self.config).returncode, 0)
        self.assertEqual(json.loads(self.config.read_text()), {
            "iris": {"bar": {"pieces": ["sound", "battery", "notifications"]}},
            "audio": {"protection": {"maxAllowedIncrease": 11}}})
        self.assertTrue(marker.exists())

    def test_apply_defaults(self):
        marker = self.state / "defaults-v1"
        self.config.write_text(json.dumps({"dock": {"autoHide": False, "pinnedApps": ["a"]}, "keep": 1}))
        self.assertEqual(self.run_script(APPLY_DEFAULTS, self.defaults, self.config, marker).returncode, 0)
        self.assertEqual(self.config.read_text(), json.dumps(
            {"dock": {"autoHide": True, "pinnedApps": ["a"]}, "keep": 1, "bar": {"glass": "on"}}, indent=4) + "\n")
        self.assertTrue(marker.exists())

    def test_house_defaults_are_objects(self):
        # apply-defaults.py trusts its own defaults files: each must be a JSON object.
        for path in sorted((HERE / "hp-snap").glob("*.json")):
            with self.subTest(path=path.name):
                self.assertIsInstance(json.loads(path.read_text()), dict)


if __name__ == "__main__":
    unittest.main()
