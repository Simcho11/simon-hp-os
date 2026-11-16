#!/usr/bin/env python3
"""Fail closed on the final desktop executable and real Ubuntu PAM conversation."""
import os
from pathlib import Path
import subprocess
import sys
from bridge import prepare


def check(root, args=()):
    manifest = Path(root) / 'share/native-pam'
    binary = manifest / 'binary'
    needed = subprocess.check_output(['patchelf', '--print-needed', str(binary)], text=True).splitlines()
    if '/usr/lib/aarch64-linux-gnu/libpam.so.0' not in needed or 'libpam.so.0' in needed:
        raise RuntimeError(f'{binary}: Ubuntu PAM linkage is required')
    bridge = Path.home() / '.local/state/hp-os/native-pam/current'
    prepare(bridge, manifest / 'pcre')
    env = dict(os.environ, QT_QPA_PLATFORM='offscreen', LC_ALL='C', USER=os.environ['USER'])
    result = subprocess.run([str(manifest / 'runner'), *args, '-n', '-p', str(Path(__file__).parent / 'probe')],
                            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    print(result.stdout)
    required = ('PAM_PASSWORD_CONVERSATION_REACHED', 'CHILD_LOADER_ENV_UNCHANGED', 'CHILD_EXIT 0', 'PAM_HOST_LIBRARY_MAPPED')
    if result.returncode or any(marker not in result.stdout for marker in required) or any(marker in result.stdout for marker in ('PAM_COMPLETED', 'PAM_ERROR')):
        raise RuntimeError(f'{root}: Ubuntu PAM conversation failed')
    print(f'Ubuntu PAM verified: {root}')

if __name__ == '__main__':
    check(sys.argv[1], sys.argv[2:])
