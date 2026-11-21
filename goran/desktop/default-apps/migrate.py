#!/usr/bin/env python3
"""Keep HP-OS's default-app lists consistent (run at each Home Manager switch).

HP-OS reads default apps from two lists, in this order:
  ~/.config/hp-os-mimeapps.list   the user's own choices; `xdg-mime default` and
                                  Files' "Open with ... always" save here
  ~/.config/mimeapps.list         HP-OS's defaults, managed by Home Manager

This keeps that true, never deleting anything (replaced files are set aside in
the migration folder, logged for the switch-back script):

1. A choice that cannot open what it was chosen for is dropped from the user's
   list: its app is installed but its command takes no file or link (a web-app
   launcher such as "Microsoft 365 Word" saved as the default for .docx or for
   ms-word: links). If that leaves only uninstalled apps for the type, the type is
   dropped too, so HP-OS's default applies. All other choices stay as they are.
2. Files kept a private list in its own settings folder, so its choices applied
   only inside Files. Valid choices from it move into the user's list, and Files
   then reads and saves the shared list through a link.
3. Some apps save a choice by replacing ~/.config/mimeapps.list, which Home
   Manager owns and would refuse to replace back. Choices that differ from
   HP-OS's defaults move into the user's list first, and the file is set aside.
"""
import argparse
import configparser
import datetime
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

USER_LIST = "hp-os-mimeapps.list"
FILE_CODES = ("%f", "%F", "%u", "%U")


class MimeList:
    """A mimeapps.list, keeping group and key order; values are lists of desktop IDs."""

    def __init__(self, text=""):
        self.groups = {}
        group = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                group = line[1:-1]
                self.groups.setdefault(group, {})
                continue
            if group is None or "=" not in line:
                continue
            key, _, value = line.partition("=")
            self.groups[group][key.strip()] = [v.strip() for v in value.split(";") if v.strip()]

    @classmethod
    def read(cls, path):
        try:
            return cls(Path(path).read_text(errors="replace"))
        except FileNotFoundError:
            return cls()

    def defaults(self):
        return self.groups.setdefault("Default Applications", {})

    def text(self):
        parts = []
        for group, entries in self.groups.items():
            parts.append(f"[{group}]")
            parts.extend(f"{key}={';'.join(ids)};" for key, ids in entries.items())
            parts.append("")
        return "\n".join(parts)


class Apps:
    """Desktop entries found in the given application folders, first folder wins."""

    def __init__(self, folders):
        self.folders = [Path(f) for f in folders if f]

    def find(self, desktop_id):
        for folder in self.folders:
            direct = folder / desktop_id
            if direct.is_file():
                return direct
            # Desktop IDs map subfolders to dashes: kde-foo.desktop may be kde/foo.desktop.
            if "-" in desktop_id:
                nested = folder / desktop_id.replace("-", "/", 1)
                if nested.is_file():
                    return nested
        return None

    def opens_files(self, desktop_id):
        """True or False for an installed app; None when it isn't installed."""
        path = self.find(desktop_id)
        if path is None:
            return None
        entry = configparser.RawConfigParser(strict=False, interpolation=None)
        entry.optionxform = str
        try:
            entry.read(path, encoding="utf-8")
            section = entry["Desktop Entry"]
        except (configparser.Error, KeyError, UnicodeDecodeError):
            return None
        if section.get("Hidden", "false").strip().lower() == "true":
            return None
        if section.get("DBusActivatable", "false").strip().lower() == "true":
            return True
        command = section.get("Exec", "")
        try:
            words = shlex.split(command)
        except ValueError:
            words = command.split()
        return any(code in word for word in words for code in FILE_CODES)


def clean(mime_list, apps):
    """Drop choices that cannot open a file. Returns a description of each change."""
    changes = []
    for group in ("Default Applications", "Added Associations"):
        entries = mime_list.groups.get(group, {})
        for mime in list(entries):
            ids = entries[mime]
            broken = [i for i in ids if apps.opens_files(i) is False]
            if not broken:
                continue
            kept = [i for i in ids if i not in broken]
            if not any(apps.opens_files(i) for i in kept):
                del entries[mime]
                changes.append(f"{group}: {mime} no longer goes to {', '.join(broken)}")
            else:
                entries[mime] = kept
                changes.append(f"{group}: {mime} keeps {', '.join(kept)} (dropped {', '.join(broken)})")
    return changes


def merge_choices(target, source, apps, managed=None):
    """Copy valid choices from source that target lacks. Returns the types added."""
    added = []
    for mime, ids in source.defaults().items():
        if mime in target.defaults():
            continue
        if managed is not None and managed.defaults().get(mime) == ids:
            continue  # the same as HP-OS's default: nothing to keep
        usable = [i for i in ids if apps.opens_files(i)]
        if usable:
            target.defaults()[mime] = usable
            added.append(mime)
    for mime, ids in source.groups.get("Added Associations", {}).items():
        current = target.groups.setdefault("Added Associations", {}).setdefault(mime, [])
        for i in ids:
            if i not in current and apps.opens_files(i):
                current.append(i)
        if not current:
            del target.groups["Added Associations"][mime]
    return added


class Migration:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

    def set_aside(self, path, mode):
        """Copy path (a file or a link) into the migration folder and log it.

        mode "replace": switching back puts this copy in place of whatever is there.
        """
        backup = self.folder / "set-aside" / self.stamp
        backup.mkdir(parents=True, exist_ok=True)
        saved = backup / Path(path).name
        n = 1
        while saved.exists() or saved.is_symlink():
            n += 1
            saved = backup / f"{Path(path).name}.{n}"
        if Path(path).is_symlink():
            os.symlink(os.readlink(path), saved)
        else:
            shutil.copy2(path, saved)
        with open(self.folder / "set-aside.log", "a") as log:
            log.write(f"{self.stamp}\t{path}\t{saved}\t{mode}\n")
        return saved


def atomic_write(path, text):
    path = Path(path)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(config_home, files_profile, migration_folder, managed_path, folders, managed_copies=(), say=print):
    config_home = Path(config_home)
    files_profile = Path(files_profile)
    apps = Apps(folders)
    migration = Migration(migration_folder)
    user_path = config_home / USER_LIST
    original = user_path.read_text(errors="replace") if user_path.exists() else None
    user = MimeList(original or "")
    managed = MimeList.read(managed_path)
    notes = []

    # 3. A choice an app saved by replacing a managed list.
    for hm_list in [config_home / "mimeapps.list", *map(Path, managed_copies)]:
        if hm_list.exists() and not hm_list.is_symlink():
            added = merge_choices(user, MimeList.read(hm_list), apps, managed)
            migration.set_aside(hm_list, "replace")
            hm_list.unlink()
            notes.append(f"kept {len(added)} choice(s) saved over {hm_list}; set it aside")

    # 2. Files' private list.
    files_list = files_profile / "mimeapps.list"
    if files_list.exists() and not files_list.is_symlink():
        added = merge_choices(user, MimeList.read(files_list), apps)
        migration.set_aside(files_list, "replace")
        files_list.unlink()
        notes.append(f"moved {len(added)} Files choice(s) into the shared list")

    # 1. Choices that cannot open a file.
    notes.extend(clean(user, apps))

    if user.groups and user.text() != (original or ""):
        if original is not None and MimeList(original).text() != user.text():
            migration.set_aside(user_path, "replace")
        config_home.mkdir(parents=True, exist_ok=True)
        atomic_write(user_path, user.text())
    elif original is None:
        config_home.mkdir(parents=True, exist_ok=True)
        atomic_write(user_path, "[Default Applications]\n")

    if files_profile.is_dir() and not (files_list.exists() or files_list.is_symlink()):
        files_list.symlink_to(user_path)
        notes.append("Files now reads and saves the shared list")
    for note in notes:
        say(f"HP-OS default apps: {note}")
    return notes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-home", required=True)
    parser.add_argument("--files-profile", required=True)
    parser.add_argument("--migration", required=True)
    parser.add_argument("--managed", required=True)
    parser.add_argument("--applications", action="append", default=[])
    parser.add_argument("--managed-copy", action="append", default=[],
                        help="another managed copy of the list, such as ~/.local/share/applications/mimeapps.list")
    args = parser.parse_args()
    run(args.config_home, args.files_profile, args.migration, args.managed, args.applications, args.managed_copy)


if __name__ == "__main__":
    sys.exit(main())
