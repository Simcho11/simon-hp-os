"""What the publishing laptop and every updating device must agree on."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

NAMESPACE = "hp-os-release"
IDENTITY = "hp-os-release"
STABLE = "stable"
CHANNEL = "channel"


def version_key(version):
    """2026.11.18.1 as something that sorts. Anything else is not a version."""
    if not isinstance(version, str) or not re.fullmatch(r"\d{4}\.\d{1,2}\.\d{1,2}\.\d{1,3}", version):
        raise ValueError("A version looks like 2026.11.18.1.")
    return tuple(int(part) for part in version.split("."))


def tree_digest(folder):
    """A fingerprint of every file's name, type and content. Git history doesn't take part."""
    folder = Path(folder)
    total = hashlib.sha256()
    entries = []
    for base, directories, files in os.walk(folder, followlinks=False):
        directories[:] = sorted(name for name in directories if name != ".git")
        for name in list(directories):
            if os.path.islink(os.path.join(base, name)):
                files.append(name)
                directories.remove(name)
        for name in files:
            entries.append(Path(base, name))
    for path in sorted(entries, key=lambda item: str(item.relative_to(folder)).encode()):
        relative = str(path.relative_to(folder)).encode()
        status = os.lstat(path)
        if stat.S_ISLNK(status.st_mode):
            kind, content = b"link", os.readlink(path).encode()
        else:
            kind = b"exec" if status.st_mode & stat.S_IXUSR else b"file"
            content = path.read_bytes()
        total.update(b"\0".join([kind, relative, hashlib.sha256(content).hexdigest().encode()]) + b"\n")
    return total.hexdigest()


def manifest_bytes(manifest):
    return (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def signature_valid(data, signature, allowed_signers, keygen="/usr/bin/ssh-keygen"):
    """True only for data signed by the publishing laptop's key."""
    result = subprocess.run([keygen, "-Y", "verify", "-f", str(allowed_signers), "-I", IDENTITY, "-n", NAMESPACE,
                             "-s", str(signature)], input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            check=False)
    return result.returncode == 0
