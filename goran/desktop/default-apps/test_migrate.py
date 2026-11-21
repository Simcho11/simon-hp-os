"""Tests for default-apps/migrate.py: user choices stay, only broken ones go, nothing is deleted."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("migrate", Path(__file__).with_name("migrate.py"))
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"


def app(folder, name, exec_line, extra=""):
    (folder / name).write_text(f"[Desktop Entry]\nType=Application\nName={name}\nExec={exec_line}\n{extra}")


class MigrateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.config = root / "config"
        self.config.mkdir()
        self.profile = self.config / "hp-os/apps/files"
        self.profile.mkdir(parents=True)
        self.state = root / "state"
        self.apps = root / "apps"
        self.apps.mkdir()
        app(self.apps, "microsoft365-word.desktop", '"/home/u/.local/bin/chrome-live-control" --app=https://word.cloud.microsoft/')
        app(self.apps, "cloud-office.desktop", "/nix/store/x/bin/cloud-office-open %U")
        app(self.apps, "rpgmaker-mz.desktop", "rpgmaker %f")
        app(self.apps, "org.kde.dolphin.desktop", "hp-os-files %U")
        app(self.apps, "chatgpt.desktop", "codex %U")
        app(self.apps, "org.gnome.Loupe.desktop", "loupe", "DBusActivatable=true\n")
        app(self.apps, "emacs.desktop", "emacs %F")
        self.managed = root / "managed.list"
        self.managed.write_text(f"[Default Applications]\n{DOCX}=cloud-office.desktop\ntext/plain=emacs.desktop\n")
        self.user = self.config / "hp-os-mimeapps.list"

    def tearDown(self):
        self.tmp.cleanup()

    def run_migration(self, copies=()):
        return migrate.run(self.config, self.profile, self.state, self.managed, [self.apps], copies, say=lambda _: None)

    def test_drops_only_choices_that_cannot_open_files(self):
        self.user.write_text(
            "[Default Applications]\n"
            "application/x-rmmzproject=rpgmaker-mz.desktop;\n"
            "inode/directory=org.kde.dolphin.desktop;\n"
            f"{DOCX}=microsoft365-word.desktop;m365-word.desktop;\n"
            "x-scheme-handler/ms-word=microsoft365-word.desktop;\n"
            "image/png=org.gnome.Loupe.desktop;\n"
            "[Added Associations]\n"
            f"{DOCX}=microsoft365-word.desktop;cloud-office.desktop;\n")
        self.run_migration()
        result = migrate.MimeList.read(self.user)
        defaults = result.defaults()
        self.assertNotIn(DOCX, defaults)  # HP-OS's default (cloud-office) applies again
        self.assertEqual(defaults["application/x-rmmzproject"], ["rpgmaker-mz.desktop"])
        self.assertEqual(defaults["inode/directory"], ["org.kde.dolphin.desktop"])
        self.assertNotIn("x-scheme-handler/ms-word", defaults)  # a launcher that takes no link
        self.assertEqual(defaults["image/png"], ["org.gnome.Loupe.desktop"])  # D-Bus apps open files
        self.assertEqual(result.groups["Added Associations"][DOCX], ["cloud-office.desktop"])
        log = (self.state / "set-aside.log").read_text().splitlines()
        self.assertEqual(len(log), 1)
        stamp, original, saved, mode = log[0].split("\t")
        self.assertEqual((original, mode), (str(self.user), "replace"))
        self.assertIn("microsoft365-word.desktop;m365-word", Path(saved).read_text())

    def test_keeps_a_type_whose_other_choice_still_works(self):
        self.user.write_text(f"[Default Applications]\n{DOCX}=microsoft365-word.desktop;cloud-office.desktop;\n")
        self.run_migration()
        self.assertEqual(migrate.MimeList.read(self.user).defaults()[DOCX], ["cloud-office.desktop"])

    def test_unchanged_list_is_left_alone(self):
        text = "[Default Applications]\napplication/x-rmmzproject=rpgmaker-mz.desktop;\n"
        self.user.write_text(text)
        (self.profile / "mimeapps.list").symlink_to(self.user)
        before = self.user.stat().st_mtime_ns
        self.assertEqual(self.run_migration(), [])
        self.assertEqual(self.user.stat().st_mtime_ns, before)
        self.assertFalse((self.state / "set-aside.log").exists())

    def test_files_private_list_moves_into_shared_list(self):
        self.user.write_text("[Default Applications]\ninode/directory=org.kde.dolphin.desktop;\n")
        private = self.profile / "mimeapps.list"
        private.write_text(
            "[Default Applications]\n"
            "x-scheme-handler/codex=chatgpt.desktop\n"
            f"{DOCX}=microsoft365-word.desktop;\n"
            "inode/directory=other.desktop;\n")
        self.run_migration()
        self.assertTrue(private.is_symlink())
        self.assertEqual(private.resolve(), self.user.resolve())
        defaults = migrate.MimeList.read(self.user).defaults()
        self.assertEqual(defaults["x-scheme-handler/codex"], ["chatgpt.desktop"])
        self.assertNotIn(DOCX, defaults)
        self.assertEqual(defaults["inode/directory"], ["org.kde.dolphin.desktop"])  # the shared list wins
        modes = [line.split("\t")[3] for line in (self.state / "set-aside.log").read_text().splitlines()]
        self.assertIn("replace", modes)

    def test_new_account_gets_a_shared_list_and_link(self):
        self.run_migration()
        self.assertEqual(self.user.read_text(), "[Default Applications]\n")
        self.assertTrue((self.profile / "mimeapps.list").is_symlink())

    def test_choice_saved_over_the_managed_list_is_kept(self):
        hm = self.config / "mimeapps.list"
        hm.write_text(f"[Default Applications]\n{DOCX}=cloud-office.desktop\ntext/plain=org.gnome.Loupe.desktop\n")
        copy = self.config / "copy.list"
        copy.symlink_to(self.managed)
        self.run_migration([copy])
        self.assertFalse(hm.exists())  # Home Manager links its own again
        self.assertTrue(copy.is_symlink())
        defaults = migrate.MimeList.read(self.user).defaults()
        self.assertEqual(defaults["text/plain"], ["org.gnome.Loupe.desktop"])  # the user's change
        self.assertNotIn(DOCX, defaults)  # same as the managed default: not copied

    def test_repeat_run_changes_nothing(self):
        self.user.write_text(f"[Default Applications]\n{DOCX}=microsoft365-word.desktop;\n")
        self.run_migration()
        before = self.user.read_text()
        self.assertEqual(self.run_migration(), [])
        self.assertEqual(self.user.read_text(), before)


if __name__ == "__main__":
    unittest.main()
