#!/usr/bin/env python3
"""Make an HP-OS launcher from an app's own desktop entry (build time).

The launcher runs the given Nix program by its full path, opens files through
Exec instead of D-Bus activation (on D-Bus the system's copy of the same app, or
none on x86, would start), and can point at the icon file when HP-OS's icon theme
has no icon for the app. The build fails if the app stops declaring a file type
HP-OS makes it the default for.
"""
import argparse
from pathlib import Path
import shlex
import sys

ICON_CANDIDATES = ["scalable/apps/{}.svg", "512x512/apps/{}.png", "256x256/apps/{}.png",
                   "128x128/apps/{}.png", "96x96/apps/{}.png", "64x64/apps/{}.png", "48x48/apps/{}.png"]


def find_icon(share, name):
    for pattern in ICON_CANDIDATES:
        path = Path(share) / "icons/hicolor" / pattern.format(name)
        if path.is_file():
            return str(path.resolve())
    return None


def rewrite_exec(value, program):
    words = shlex.split(value)
    if not words:
        raise SystemExit(f"empty Exec line: {value!r}")
    if Path(words[0]).name != Path(program).name:
        raise SystemExit(f"Exec starts with {words[0]!r}, expected {Path(program).name!r}")
    rest = value.split(None, 1)[1] if len(value.split(None, 1)) > 1 else ""
    return (program + " " + rest).rstrip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--entry", required=True)
    parser.add_argument("--program", required=True)
    parser.add_argument("--share", required=True)
    parser.add_argument("--icon-file", action="store_true")
    parser.add_argument("--types", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    lines = Path(args.entry).read_text().splitlines()
    out = []
    declared = set()
    group = ""
    saw_exec = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            group = stripped
            out.append(line)
            continue
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep:
            out.append(line)
            continue
        if key == "DBusActivatable":
            continue
        if key in ("Exec", "TryExec"):
            value = rewrite_exec(value, args.program) if key == "Exec" else args.program
            saw_exec = saw_exec or (group == "[Desktop Entry]" and key == "Exec")
        elif key == "Icon" and args.icon_file and group == "[Desktop Entry]":
            icon = find_icon(args.share, value.strip())
            if icon is None:
                raise SystemExit(f"no icon file for {value.strip()!r} in {args.share}")
            value = icon
        elif key == "MimeType" and group == "[Desktop Entry]":
            declared = {m for m in value.split(";") if m}
        out.append(f"{key}={value}")
    if not saw_exec:
        raise SystemExit("the entry has no Exec line")
    wanted = {m for m in args.types.split(";") if m}
    missing = sorted(wanted - declared)
    if missing:
        raise SystemExit(f"{args.entry} no longer declares: {' '.join(missing)}")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    sys.exit(main())
