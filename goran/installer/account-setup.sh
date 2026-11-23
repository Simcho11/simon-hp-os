#!/bin/bash
# Called as the account owner, from the shared installer or on HP-OS session entry.
set -euo pipefail
export PATH=/usr/bin:/bin
export HP_OS_ACCOUNT
HP_OS_ACCOUNT=$(id -un)
(( EUID != 0 )) || { echo 'Run account setup as the desktop user.' >&2; exit 1; }
[[ "$HOME" == "$(getent passwd "$HP_OS_ACCOUNT" | cut -d: -f6)" && "$HOME" == "/home/$HP_OS_ACCOUNT" ]] || exit 1
state="${XDG_STATE_HOME:-$HOME/.local/state}"
profile="$state/nix/profiles/home-manager"
dir="$state/hp-os/enrollment"
mkdir -p "$dir"
ready() {
    [[ -x "$profile/home-path/bin/hp-os" && -r "$state/hp-os/native-pam/current/libpam.so.0" && -f "$dir/source" && $(cat "$dir/source") == "$HP_OS_PROFILE_FLAKE" ]]
}
# --needed: answers only (exit 0 when this account still has to be set up).
if [[ ${1:-} == --needed ]]; then
    if ready; then exit 1; else exit 0; fi
fi
exec 9>"$dir/activation.lock"
flock 9
if [[ ${1:-} != --apply ]] && ready; then
    exit 0
fi

# How this attempt went, in $dir/outcome, for the sign-in (hp-os-login-session): "running" while it runs (left as is if
# it was stopped), then "ok" or "failed REASON", REASON telling the login screen what to say: storage (the disk is
# full), network (something had to be downloaded and couldn't be) or other. Never what fails the setup itself.
log_start=$(stat -c %s "$dir/setup.log" 2>/dev/null || echo 0)
record_outcome() {
    local status=$? reason=other free recent
    set +e
    trap - EXIT
    if (( status == 0 )); then
        { printf 'ok\n' > "$dir/outcome.new" && mv -fT "$dir/outcome.new" "$dir/outcome"; } 2>/dev/null
        exit 0
    fi
    # What this attempt wrote to the log (with a progress bar its output goes there; otherwise to the journal).
    recent=$(tail -c +"$((log_start + 1))" "$dir/setup.log" 2>/dev/null | tail -c 65536)
    free=$(df -Pk /nix/store "$HOME" 2>/dev/null | awk 'NR > 1 && (least == "" || $4 < least) { least = $4 } END { print least + 0 }')
    if [[ "$recent" == *"No space left on device"* ]] || (( ${free:-0} > 0 && free < 1048576 )); then
        reason=storage
    elif grep -Eqi 'unable to download|could not resolve|resolve host|network is unreachable|connection timed out|connection refused|temporary failure in name resolution' <<< "$recent"; then
        reason=network
    fi
    { printf 'failed %s\n' "$reason" > "$dir/outcome.new" && mv -fT "$dir/outcome.new" "$dir/outcome"; } 2>/dev/null
    exit "$status"
}
{ printf 'running\n' > "$dir/outcome.new" && mv -fT "$dir/outcome.new" "$dir/outcome"; } 2>/dev/null || true
trap record_outcome EXIT

# With HP_OS_SETUP_PROGRESS=1, stdout carries "HP-OS-PROGRESS <percent>" lines for a progress bar.
report() {
    if [[ ${HP_OS_SETUP_PROGRESS:-} == 1 ]]; then printf 'HP-OS-PROGRESS %d\n' "$1"; fi
}
follow_build() {    # Nix's log: 30-75 %
    local total=0 finished=0 line
    while IFS= read -r line; do
        printf '%s\n' "$line" >&2
        case "$line" in
            *"will be built:"*) total=${line//[!0-9]/}; total=${total:-1} ;;
            "building '"*)
                finished=$((finished + 1))
                if (( total > 0 )); then report $(( 30 + 45 * (finished > total ? total : finished) / total )); fi ;;
        esac
    done
}
follow_activation() {    # Home Manager's steps: 75-99 %
    local total=$1 finished=0 line
    while IFS= read -r line; do
        printf '%s\n' "$line" >&2
        case "$line" in
            Activating\ *)
                finished=$((finished + 1))
                if (( total > 0 )); then report $(( 75 + 24 * (finished > total ? total : finished) / total )); fi ;;
        esac
    done
}
if [[ ${HP_OS_SETUP_PROGRESS:-} == 1 ]]; then exec 2>>"$dir/setup.log"; fi
report 3
# Pin the candidate throughout activation. The Home Manager profile roots it on success.
nix --extra-experimental-features 'nix-command flakes' build --offline --log-format raw --out-link "$dir/candidate" --impure --expr '
  let source = builtins.getFlake (builtins.getEnv "HP_OS_PROFILE_FLAKE");
  in (source.lib.hpOsAccount (builtins.getEnv "HP_OS_ACCOUNT")).activationPackage' 2>&1 | follow_build
report 75
steps=$(grep -c '_iNote "Activating' "$dir/candidate/activate" || true)
export HOME_MANAGER_BACKUP_EXT="before-hp-os-$(date +%s%N)"
export HP_OS_ACCOUNT_PROVISION=1
if [[ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    "$dir/candidate/activate" 9>&- </dev/null 2>&1 | follow_activation "$steps"
else
    /usr/bin/dbus-run-session --dbus-daemon=/usr/bin/dbus-daemon --config-file=/usr/share/dbus-1/session.conf -- "$dir/candidate/activate" 9>&- </dev/null 2>&1 | follow_activation "$steps"
fi
[[ "$(readlink -f "$profile")" == "$(readlink -f "$dir/candidate")" && -r "$state/hp-os/native-pam/current/libpam.so.0" ]]
printf '%s\n' "$HP_OS_PROFILE_FLAKE" > "$dir/source.new"
mv -fT "$dir/source.new" "$dir/source"
report 100
