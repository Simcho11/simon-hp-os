#!/usr/bin/env python3
"""HP-OS's default window look in a niri config.kdl: no outline, and HarmonyOS's soft shadows.

Usage: window-style.py CONFIG.KDL [MARKER]
With MARKER it runs once per account, so a look chosen later in Settings is never overwritten.
"""
import os
import pathlib
import re
import sys
import tempfile

RING = """focus-ring {
        off
        width 3
        active-color "#3377ff"
        inactive-color "#90949c"
    }"""
SHADOW = """// HP-OS: soft, wide shadows modelled on HarmonyOS, deeper under the window in use.
    shadow {
        on
        softness 20
        spread 8
        offset x=0 y=12
        color "#00000047"
        inactive-color "#0000001f"
    }"""


def block_end(text, opening):
    depth = 0
    for index in range(opening, len(text)):
        depth += (text[index] == "{") - (text[index] == "}")
        if depth == 0:
            return index
    raise ValueError("unbalanced braces")


def styled(text):
    found = re.search(r"(?m)^layout\s*\{", text)
    if not found:
        return text
    opening = found.end() - 1
    closing = block_end(text, opening)
    body = text[opening + 1:closing]
    if re.search(r"focus-ring\s*\{\s*off\b", body) and "softness 20" in body and "shadow { on; }" not in text:
        return text  # Already this look.
    ring = re.search(r"focus-ring\s*\{", body)
    if ring:
        end = block_end(body, ring.end() - 1)
        body = body[:ring.start()] + RING + body[end + 1:]
    else:
        body = body.rstrip() + "\n    " + RING + "\n"
    shadow = re.search(r"(?m)^\s*shadow\s*\{", body)
    if shadow:
        end = block_end(body, shadow.end() - 1)
        body = body[:shadow.start()].rstrip(" ") + "    " + SHADOW + body[end + 1:]
    else:
        body = body.rstrip() + "\n    " + SHADOW + "\n"
    text = text[:opening + 1] + body + text[closing:]
    # HP-OS's stock per-window shadow would replace the layout's soft one.
    return re.sub(r"(?m)^[ \t]*shadow \{ on; \}[ \t]*\n", "", text)


def main():
    path = pathlib.Path(sys.argv[1])
    marker = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if not path.is_file() or (marker and marker.exists()):
        return
    old = path.read_text()
    new = styled(old)
    if new != old:
        fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(new)
            os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    if marker:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.touch()


main()
