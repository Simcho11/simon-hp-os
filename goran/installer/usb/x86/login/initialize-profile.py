#!/usr/bin/python3
"""Initialize a user's HP-OS profile from shared, non-personal defaults."""
import json
import os
from pathlib import Path
import pwd
import runpy
import stat

PACKAGING = Path('@PACKAGING@')

def exclusive_json(path, data):
    try:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    except FileExistsError:
        return
    with os.fdopen(fd,'w') as stream:
        json.dump(data,stream,indent=2);stream.write('\n')

def initialize(home):
    home=Path(home)
    if home.is_symlink() or home.stat().st_uid!=os.getuid():
        raise RuntimeError('HP-OS profile home must belong to the signed-in user.')
    # Traverse only owned, real directories. Never seed through another user's symlink.
    def directory(relative):
        current=home
        for part in Path(relative).parts:
            current=current/part
            current.mkdir(mode=0o700,exist_ok=True)
            if current.is_symlink() or not current.is_dir() or current.stat().st_uid!=os.getuid():
                raise RuntimeError('Unsafe profile directory: '+str(current))
        return current
    config=directory('.config/hp-os')
    state=directory('.local/state/hp-os')
    directory('.local/share/hp-os')
    directory('.cache/hp-os')
    fresh=not (config/'config.json').exists()
    if fresh:
        home.chmod(0o700)
        defaults=json.loads((PACKAGING/'default-config.json').read_text())
        defaults.setdefault('background',{})['wallpaperPath']=str(PACKAGING/'assets/hpos-wallpaper.png')
        defaults.setdefault('lock',{})['launchOnStartup']=False
        exclusive_json(config/'config.json',defaults)
    exclusive_json(state/'profile.json',{
        'schemaVersion':1,'product':'HP-OS','uid':os.getuid(),
        'username':pwd.getpwuid(os.getuid()).pw_name,
        'setup':'initialized','source':'shared-defaults' if fresh else 'existing-profile'
    })
    return fresh

if __name__=='__main__':
    os.umask(0o077)
    # The account database is authoritative, not a caller-provided HOME.
    home=Path(pwd.getpwuid(os.getuid()).pw_dir)
    if Path.home()!=home:
        raise SystemExit('Home directory does not match the signed-in account.')
    initialize(home)
