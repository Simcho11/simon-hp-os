#!/usr/bin/env python3
"""Give a niri config.kdl the Liquid Glass settings tuned on Simon's account (2026-11-10).

HP-OS ships its glass layer rule with `xray true`: niri then blurs a separate copy of the
wallpaper behind the Dock, menus and notifications. While desktops scroll (hp-snap's desktop
pages) that copy no longer lines up, so the glass shows grey or moving content. With
`xray false` niri blurs what is really behind the glass, which stays right while scrolling.

Idempotent; changes only what differs. Usage: glass-niri.py CONFIG.KDL
"""
import os
import pathlib
import re
import sys
import tempfile

GLASS_NAMESPACE = 'match namespace="^(hpos|quickshell:iris-(chassis|dock|control|settings|notifications|palette|launcher|menu)).*"'
OTHER_RULE = '''// The shell's other surfaces ask for blur themselves, shape by shape: they only need the same view.
layer-rule {
    match namespace="^quickshell:iris-(osd|sidebar|session|osk|studio|orbit)"
    match namespace="^quickshell:iris-workspace-rail$"
    background-effect { xray false; }
}
'''
BLUR_BLOCK = '''
// Niri's blur behind surfaces that ask for it (iRiS glass set to Blur).
blur {
    passes 2
    offset 2.0
    saturation 1
}
'''


def fix(text: str) -> str:
    start = text.find(GLASS_NAMESPACE)
    if start >= 0:
        rule_start = text.rfind("layer-rule", 0, start)
        end = text.find("\n}", start)
        if rule_start >= 0 and end >= 0:
            rule = text[rule_start:end]
            fixed = re.sub(r"xray\s+true", "xray false", rule)
            text = text[:rule_start] + fixed + text[end:]
            end = rule_start + len(fixed)
            if "iris-(osd|sidebar|session|osk|studio|orbit)" not in text:
                after = end + len("\n}\n")
                text = text[:after] + OTHER_RULE + text[after:]
    if not re.search(r"(?m)^blur\s*\{", text):
        text = text.rstrip("\n") + "\n" + BLUR_BLOCK
    return text


def main() -> int:
    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        return 0
    old = path.read_text()
    new = fix(old)
    if new == old:
        return 0
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(new)
        os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Liquid Glass niri settings applied to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
