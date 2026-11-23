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
    # A config.json that can't be read as HP-OS settings is left as it is and not marked, so the
    # defaults go in on a later run once it is whole again.
    if not _apply(path):
        return
    if marker:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("applied\n")


def _skip(path, reason):
    # This runs in every Home Manager update: a damaged config.json must not stop the rest of it.
    print(f"hp-os-battery: left {path} as it is ({reason})", file=sys.stderr)
    return False


def _apply(path):
    """Returns False when the file was left alone because it isn't usable HP-OS settings."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError, RecursionError) as error:
        return _skip(path, error)
    if not isinstance(data, dict):
        return _skip(path, "not a JSON object")
    iris = data.setdefault("iris", {})
    bar = iris.setdefault("bar", {}) if isinstance(iris, dict) else None
    if not isinstance(bar, dict):
        return _skip(path, "iris.bar is not an object")
    pieces = bar.get("pieces", ["sound"])
    if not isinstance(pieces, list):
        return _skip(path, "iris.bar.pieces is not a list")
    before = json.dumps(data, sort_keys=True)
    bar["pieces"] = pieces + [piece for piece in ("battery", "notifications") if piece not in pieces]
    audio = data.setdefault("audio", {})
    protection = audio.setdefault("protection", {}) if isinstance(audio, dict) else None
    if not isinstance(protection, dict):
        return _skip(path, "audio.protection is not an object")
    if protection.get("maxAllowedIncrease", 10) == 10:
        protection["maxAllowedIncrease"] = 11
    if json.dumps(data, sort_keys=True) == before:
        return True
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
    return True


if __name__ == "__main__":
    for filename in sys.argv[1:]:
        enable(filename)
