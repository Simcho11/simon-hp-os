#!/bin/bash
# Debug aid: record what happens during "Switch user", twice a second, to ~/hpos-switch-trace.log.
# Needs no root. Runs until stopped (Ctrl+C or kill), or for at most 5 minutes.
out="$HOME/hpos-switch-trace.log"
runtime="${1:-$HOME/.local/share/hp-snap/hpos-shell-patch/inir-next}"
: > "$out"
end=$((SECONDS + 300))
while (( SECONDS < end )); do
  {
    echo "=== $(date +%T.%N | cut -c1-12)  active VT: $(cat /sys/class/tty/tty0/active 2>/dev/null)"
    loginctl list-sessions --no-legend 2>/dev/null | while read -r id _ user seat _ _ tty _; do
      echo "  session $id $user ${tty:--} $(loginctl show-session "$id" -p State -p Active -p Class --value 2>/dev/null | tr '\n' ' ')"
    done
    echo "  lock: $(timeout 1 qs ipc -p "$runtime" call lock status 2>&1 | tr '\n' ' ')"
    ps -eo pid,etime,user,args 2>/dev/null | grep -E 'switch-user\.py|sddm-greeter|greeter-compositor|sddm-helper|notify-send' \
      | grep -v grep | cut -c1-160 | sed 's/^/  /'
  } >> "$out"
  sync "$out" 2>/dev/null
  sleep 0.5
done
