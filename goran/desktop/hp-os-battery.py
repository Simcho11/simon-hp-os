"""Apply shared HP-OS notification and volume defaults, preserving other settings."""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def marker_for(path):
    """An account's own config.json gets these defaults once; after that, what the person sets in
    Settings stays (the Island's bubbles, Largest jump). The packaged default config has no marker."""
    if path != (Path.home() / ".config/hp-os/config.json").resolve():
        return None
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    return state / "hp-os/hp-os-battery-v1"


def enable(path):
    path = Path(path).resolve()
    if not path.is_file():
        return
    marker = marker_for(path)
    if marker and marker.exists():
        return
    _apply(path)
    if marker:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("applied\n")


def _apply(path):
    data = json.loads(path.read_text())
    bar = data.setdefault("iris", {}).setdefault("bar", {})
    pieces = bar.get("pieces", ["sound"])
    if not isinstance(pieces, list):
        raise ValueError(f"Expected iris.bar.pieces array in {path}")
    before = json.dumps(data, sort_keys=True)
    bar["pieces"] = pieces + [piece for piece in ("battery", "notifications") if piece not in pieces]
    protection = data.setdefault("audio", {}).setdefault("protection", {})
    if protection.get("maxAllowedIncrease", 10) == 10:
        protection["maxAllowedIncrease"] = 11
    if json.dumps(data, sort_keys=True) == before:
        return
    fd, temporary = tempfile.mkstemp(prefix=".battery-", dir=path.parent)
    try:
        os.fchmod(fd, stat.S_IMODE(path.stat().st_mode))
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    for filename in sys.argv[1:]:
        enable(filename)
