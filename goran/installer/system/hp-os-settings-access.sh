#!/bin/bash
# Lets every HP-OS account use the settings that need the machine's help. Run by hp-os-add-user.sh.
#
#   sudo goran/installer/system/hp-os-settings-access.sh          install / update
#   sudo goran/installer/system/hp-os-settings-access.sh --undo   take it out again
#
#   Brightness      any account may run the one panel tool, which only accepts a brightness value
#   Touchpad        whoever is at the screen may reach the touchpad's feedback controls
#   AirDrop         the installed AirDrop is published to all accounts, who may all use its radio
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
admin="${SUDO_USER:-}"
[[ -n "$admin" && "$admin" != root ]] || { echo "Run with sudo from your own account." >&2; exit 1; }

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
rule=/etc/sudoers.d/hp-os-brightness
brightness_root=/nix/var/nix/gcroots/hp-os-brightness
touchpad=/etc/udev/rules.d/70-touchpad-haptics.rules
airdrop=/nix/var/nix/profiles/hp-os-airdrop

people() { getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ "^/home/" { print $1 }'; }

if [[ "${1:-}" == --undo ]]; then
    rm -f "$rule" "$brightness_root" "$airdrop" "$airdrop"-*-link
    if getent group omdrop >/dev/null; then
        for person in $(people); do
            [[ "$person" == "$admin" ]] || gpasswd -d "$person" omdrop >/dev/null 2>&1 || true
        done
    fi
    echo "Shared settings access removed."
    exit 0
fi

# Brightness. A broken sudoers file can lock out sudo, so it is checked before and after it goes in.
control=$(sed -n 's/^+control=//p' "$repo/goran/desktop/hp-snap/shell.patch" | head -n 1)
if [[ -x "$control" ]]; then
    python=$(sed -n 's/^export GORAN_PANEL_PYTHON=//p' "$control")
    script=$(sed -n 's/^export GORAN_PANEL_SCRIPT=//p' "$control")
    [[ -x "$python" && -r "$script" ]] || { echo "The brightness tool is incomplete; nothing changed." >&2; exit 1; }
    candidate=$(mktemp)
    printf 'ALL ALL=(root) NOPASSWD: %s %s *\n' "$python" "$script" > "$candidate"
    visudo -cqf "$candidate" || { rm -f "$candidate"; echo "Brightness rule is not valid; nothing changed." >&2; exit 1; }
    install -m 440 -o root -g root "$candidate" "$rule"
    rm -f "$candidate"
    visudo -cq || { rm -f "$rule"; echo "Brightness rule was refused and removed." >&2; exit 1; }
    ln -sfn "$(dirname "$(dirname "$control")")" "$brightness_root"
fi

# Touchpad feedback, for whichever haptic touchpad this laptop has (none on a laptop with a regular touchpad).
wanted=""
for ids in $(/usr/bin/python3 -I "$repo/goran/desktop/hp-snap/touchpad-haptics.py" ids 2>/dev/null); do
    [[ "$ids" =~ ^[0-9A-F]{4}:[0-9A-F]{4}$ ]] || continue
    wanted+="SUBSYSTEM==\"hidraw\", KERNELS==\"*:$ids.*\", TAG+=\"uaccess\""$'\n'
done
if [[ "$(cat "$touchpad" 2>/dev/null)"$'\n' != "$wanted" && -n "$wanted$(cat "$touchpad" 2>/dev/null)" ]]; then
    if [[ -n "$wanted" ]]; then printf '%s' "$wanted" > "$touchpad"; else rm -f "$touchpad"; fi
    udevadm control --reload
    udevadm trigger --subsystem-match=hidraw
fi

# AirDrop, only where it has been set up. Group changes apply from each person's next sign-in.
gui=$(readlink -f "/home/$admin/.config/hp-os/omdrop" 2>/dev/null || true)
if [[ "$gui" == /nix/store/*/share/omdrop && -r "$gui/OmdropPanel.qml" ]] && getent group omdrop >/dev/null; then
    /usr/bin/nix-env --profile "$airdrop" --set "${gui%/share/omdrop}"
    for person in $(people); do usermod -aG omdrop "$person"; done
fi
echo "Brightness, touchpad feedback and AirDrop are available to every account."
