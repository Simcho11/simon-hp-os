#!/bin/bash
# Activate the published Home Manager desktop for one local HP-OS account.
set -euo pipefail
[[ $EUID == 0 && $# == 1 ]] || { echo "Usage: sudo $0 USERNAME" >&2; exit 2; }
account=$1
setup=/nix/var/nix/profiles/hp-os-accounts/bin/hp-os-account-setup
[[ -x "$setup" ]] || { echo 'Publish the desktop with system/hp-os-login-session.sh first.' >&2; exit 1; }
entry=$(getent -s files passwd "$account")
IFS=: read -r name _ uid _ _ directory shell <<< "$entry"
[[ "$name" == "$account" && $uid -ge 1000 && $uid -le 60000 && "$directory" == "/home/$name" && "$shell" != */nologin && "$shell" != */false ]]
ACTION=useradd SUBJECT="$account" /etc/shadow-maint/useradd-post.d/hp-os-nix-group
runtime=/run/user/$uid
env_args=(HOME="$directory" USER="$account" LOGNAME="$account" PATH=/usr/bin:/bin)
[[ ! -d "$runtime" ]] || env_args+=(XDG_RUNTIME_DIR="$runtime")
sudo -u "$account" -- env -i "${env_args[@]}" "$setup" --apply
echo "Home Manager activated for $account."
