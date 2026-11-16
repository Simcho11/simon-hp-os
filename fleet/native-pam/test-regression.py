#!/usr/bin/env python3
"""Exercise the deployment guard against the original regression executables."""
from pathlib import Path
import subprocess
import sys
import tempfile

check = Path(__file__).with_name('check.py')
patched, original = map(Path, sys.argv[1:])

def run(root, succeeds):
    result = subprocess.run([sys.executable, str(check), str(root)], capture_output=True, text=True)
    print(result.stdout, result.stderr)
    assert (result.returncode == 0) == succeeds, root

run(patched, True)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    run(root, False)  # Package refactor dropped the native PAM override.
    manifest = root / 'share/hp-os-native-pam'
    manifest.mkdir(parents=True)
    for name in ('runner', 'binary', 'pcre'):
        (manifest / name).symlink_to(patched / 'share/hp-os-native-pam' / name)
    (manifest / 'binary').unlink()
    (manifest / 'binary').symlink_to(original / 'bin/.quickshell-wrapped')
    run(root, False)  # Candidate still links to Nix PAM.
    (manifest / 'binary').unlink()
    (manifest / 'binary').symlink_to(patched / 'share/hp-os-native-pam/binary')
    (manifest / 'runner').unlink()
    (manifest / 'runner').symlink_to(original / 'bin/qs')
    run(root, False)  # Metadata is correct, launcher reaches the old ELF.
print('Native PAM regression cases passed')
