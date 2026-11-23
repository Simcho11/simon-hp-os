set -euo pipefail

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/goran-brightness"
mkdir -p "$state_dir"
exec 9>"$state_dir/lock"
flock -x 9

# Laptops whose screen the panel tool can't drive (the OmniBook X's, Intel laptops): the screen's own backlight,
# through logind like any desktop. Only where the tool has never set a level, since on the OmniBook Ultra's OLED the
# backlight would undo the tool's luminance mode. (GORAN_BACKLIGHTS, GORAN_BUSCTL and GORAN_SUDO are for tests.)
backlight_fallback() {
  [[ ! -f "$state_dir/percent" ]] || return 1
  local path device="" kind rank best=9 max now step target
  for path in "${GORAN_BACKLIGHTS:-/sys/class/backlight}"/*; do
    [[ -r "$path/max_brightness" && -r "$path/brightness" ]] || continue
    kind=$(cat "$path/type" 2>/dev/null || true)
    case "$kind" in firmware) rank=0;; platform) rank=1;; *) rank=2;; esac
    if (( rank < best )); then best=$rank; device=$path; fi
  done
  [[ -n "$device" ]] || return 1
  max=$(cat "$device/max_brightness"); now=$(cat "$device/brightness")
  [[ "$max" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] && (( max > 0 )) || return 1
  step=$(( max * 5 / 100 )); (( step >= 1 )) || step=1
  case "$1" in
    up) target=$(( now + step ));;
    down) target=$(( now - step ));;
    set) target=$(( max * $2 / 100 ));;
    *) return 0;;      # restore: the backlight keeps its own level from one start to the next
  esac
  (( target <= max )) || target=$max
  (( target >= step )) || target=$step     # never fully dark
  "${GORAN_BUSCTL:-/usr/bin/busctl}" call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
    org.freedesktop.login1.Session SetBrightness ssu backlight "${device##*/}" "$target"
}

percent=100
if [[ -f "$state_dir/percent" ]]; then
  read -r saved < "$state_dir/percent" || true
  if [[ "$saved" =~ ^[0-9]+$ ]] && (( saved >= 5 && saved <= 100 )); then
    percent=$saved
  fi
fi

case "${1:-status}" in
  up) percent=$(( percent + 5 ));;
  down) percent=$(( percent - 5 ));;
  restore) ;;
  set)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo 'usage: goran-brightness set 5..100' >&2; exit 2; }
    percent=$2
    ;;
  status)
    printf 'saved_percent=%s\n' "$percent"
    "${GORAN_SUDO:-/usr/bin/sudo}" -n "$GORAN_PANEL_PYTHON" "$GORAN_PANEL_SCRIPT"
    exit
    ;;
  *) echo 'usage: goran-brightness up|down|restore|set 5..100|status' >&2; exit 2;;
esac

(( percent < 5 )) && percent=5
(( percent > 100 )) && percent=100
# Map 5..100 percent to 10..500 cd/m². The EDID's full-screen limit is 500.
nits=$(( 10 + (percent - 5) * 490 / 95 ))
if ! "${GORAN_SUDO:-/usr/bin/sudo}" -n "$GORAN_PANEL_PYTHON" "$GORAN_PANEL_SCRIPT" "$(( nits * 1000 ))"; then
  backlight_fallback "${1:-}" "${2:-}" && exit 0
  exit 1
fi
printf '%s\n' "$percent" > "$state_dir/percent.tmp"
mv "$state_dir/percent.tmp" "$state_dir/percent"
