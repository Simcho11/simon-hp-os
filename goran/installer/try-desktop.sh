#!/usr/bin/env bash
# Try a new HP-OS desktop build, with a one-command way back.
#
#   try-desktop.sh start <home-manager activation package>
#       Records the desktop you have now, then switches to the new build.
#   ~/.local/state/hp-os/trial/switch-back
#       Undoes the most recent start: returns to the desktop recorded then, and
#       puts back the files that switch set aside. Run it again to undo the one
#       before. Safe to run more than once.
#   ~/.local/state/hp-os/trial/switch-back keep
#       Keeps the most recent install and forgets its record (earlier ones stay;
#       "keep all" forgets every record).
#
# Each start is one numbered record (trial/1, trial/2, ...), so two people or
# sessions trying builds one after the other each undo only their own.
# The records live outside Home Manager, so switching back does not remove them.
set -euo pipefail

state="${XDG_STATE_HOME:-$HOME/.local/state}"
trial="$state/hp-os/trial"
migration="$state/hp-os/files-migration"
profile="$state/nix/profiles/home-manager"

say() { printf '%s\n' "$*"; }
stamp() { date +%Y%m%d-%H%M%S; }

current_generation() {
  local link
  link=$(readlink -f "$profile" 2>/dev/null || true)
  [[ -n "$link" && -x "$link/activate" ]] || { say "Can't find the current desktop generation ($profile)." >&2; exit 1; }
  printf '%s\n' "$link"
}

# Records from before numbering: trial/previous becomes trial/1.
upgrade_layout() {
  [[ -e "$trial/previous" || -L "$trial/previous" ]] || return 0
  mkdir -p "$trial/1"
  mv "$trial/previous" "$trial/1/previous"
  [[ -e "$trial/candidate" || -L "$trial/candidate" ]] && mv "$trial/candidate" "$trial/1/candidate"
  local started=""
  if [[ -f "$trial/started" ]]; then
    started=$(date -d "$(cat "$trial/started")" +%Y%m%d-%H%M%S 2>/dev/null || true)
    rm -f "$trial/started"
  fi
  printf '%s\n' "${started:-00000000-000000}" > "$trial/1/started"
}

latest() {
  local n
  n=$(find "$trial" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' 2>/dev/null | sort -n | tail -1)
  printf '%s\n' "$n"
}

start() {
  local candidate="${1:?usage: try-desktop.sh start <activation package>}"
  candidate=$(readlink -f "$candidate")
  [[ -x "$candidate/activate" ]] || { say "$candidate is not a Home Manager activation package." >&2; exit 1; }
  mkdir -p "$trial"
  upgrade_layout
  local n previous
  n=$(latest); n=$(( ${n:-0} + 1 ))
  mkdir -p "$trial/$n"
  previous=$(current_generation)
  # Keep the recorded desktop from garbage collection until the trial ends.
  nix-store --add-root "$trial/$n/previous" --realise "$previous" >/dev/null
  nix-store --add-root "$trial/$n/candidate" --realise "$candidate" >/dev/null
  stamp > "$trial/$n/started"
  install -m 755 "$(readlink -f "${BASH_SOURCE[0]}")" "$trial/switch-back"
  say "Recorded the current desktop as record $n: $previous"
  say "Switching to the new desktop: $candidate"
  "$candidate/activate"
  say ""
  say "Done. Close and reopen Files to use the new one."
  say "To go back:          $trial/switch-back"
  say "To keep this build:  $trial/switch-back keep"
}

# Puts back what was set aside at or after $1 (a stamp), newest first, and
# removes those lines from the log. Lines: stamp, original, saved copy, mode.
# Without "replace" a copy returns only where nothing is in its place now; with
# it the copy (a file or a link) replaces whatever the new build put there.
restore_set_aside() {
  local since="$1" log="$migration/set-aside.log"
  [[ -f "$log" ]] || return 0
  local keep_lines restored_lines stamp_ original saved mode
  keep_lines=$(mktemp) restored_lines=$(mktemp)
  while IFS=$'\t' read -r stamp_ original saved mode; do
    if [[ "$stamp_" < "$since" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$stamp_" "$original" "$saved" "$mode" >> "$keep_lines"
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$stamp_" "$original" "$saved" "$mode" >> "$restored_lines"
  done < "$log"
  while IFS=$'\t' read -r stamp_ original saved mode; do
    [[ -n "$original" ]] || continue
    [[ -e "$saved" || -L "$saved" ]] || continue
    if [[ "$mode" != replace && ( -e "$original" || -L "$original" ) ]]; then
      continue
    fi
    mkdir -p "$(dirname "$original")"
    rm -f "$original"
    cp -P -p "$saved" "$original"
    say "Put back $original"
  done < <(tac "$restored_lines")
  cat "$restored_lines" >> "$log.restored"
  if [[ -s "$keep_lines" ]]; then mv "$keep_lines" "$log"; else rm -f "$keep_lines" "$log"; fi
  rm -f "$restored_lines"
}

back() {
  upgrade_layout
  local n previous since
  n=$(latest)
  [[ -n "$n" ]] || { say "No recorded desktop to switch back to." >&2; exit 1; }
  previous=$(readlink -f "$trial/$n/previous")
  since=$(cat "$trial/$n/started" 2>/dev/null || echo 00000000-000000)
  say "Switching back to record $n: $previous"
  "$previous/activate" || say "(The last activation step may need an administrator password; the desktop itself is switched.)"
  restore_set_aside "$since"
  # "Show in folder" is served by a background Files; let the old setup take it over.
  pkill -u "$(id -u)" -f -- '-dolphin.*/bin/(\.dolphin-wrapped|dolphin) .*--daemon' 2>/dev/null || true
  rm -rf "${trial:?}/$n"
  say ""
  say "Back on the desktop recorded as record $n. Close and reopen Files."
  if [[ -n "$(latest)" ]]; then
    say "An earlier record remains; run $trial/switch-back again to undo that one too."
  fi
}

# Accepts the most recent install: forgets its record, leaving earlier ones
# (another person's or session's trial) as they are. "keep all" forgets every record.
keep() {
  upgrade_layout
  local n since log="$migration/set-aside.log"
  if [[ "${1:-}" == all ]]; then
    find "$trial" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -exec rm -rf {} +
    [[ -f "$log" ]] && mv "$log" "$log.kept-$(stamp)"
    say "Kept the current desktop and forgot every record."
    return 0
  fi
  n=$(latest)
  [[ -n "$n" ]] || { say "No trial to keep."; return 0; }
  since=$(cat "$trial/$n/started" 2>/dev/null || echo 00000000-000000)
  # What this install set aside stays in the migration folder, out of later switch-backs.
  if [[ -f "$log" ]]; then
    awk -F'\t' -v s="$since" '$1 >= s' "$log" >> "$log.kept-$(stamp)"
    awk -F'\t' -v s="$since" '$1 < s' "$log" > "$log.rest"
    if [[ -s "$log.rest" ]]; then mv "$log.rest" "$log"; else rm -f "$log.rest" "$log"; fi
  fi
  rm -rf "${trial:?}/$n"
  say "Kept the current desktop (record $n). Earlier ones stay available as Home Manager generations."
  if [[ -n "$(latest)" ]]; then
    say "An earlier record ($(latest)) remains for whoever started it."
  fi
}

case "${1:-back}" in
  start) shift; start "$@" ;;
  back) back ;;
  keep) shift; keep "${1:-}" ;;
  *) say "usage: $0 start <activation package> | back | keep [all]" >&2; exit 2 ;;
esac
