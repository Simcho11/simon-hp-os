# Launcher and screenshot helpers ported from Slazenger nixos-intc.
{ config, pkgs, ... }:
{
  home.file.".local/bin/fuzzel-focused".text = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    if [ -x ${config.programs.dank-material-shell.package}/bin/dms ]; then
      # DMS may still be visible after its Quickshell event loop wedges. Never
      # let a courtesy overlay-close prevent the independent launcher opening.
      for target in spotlight launcher keybinds; do
        ${pkgs.coreutils}/bin/timeout --kill-after=0.15s 0.35s \
          ${config.programs.dank-material-shell.package}/bin/dms ipc "$target" close \
          >/dev/null 2>&1 || true
      done
    fi

    exec ${pkgs.fuzzel}/bin/fuzzel \
      --layer=overlay \
      --keyboard-focus=exclusive \
      --no-exit-on-keyboard-focus-loss \
      --launch-prefix=${config.home.homeDirectory}/.local/bin/fuzzel-launch \
      "$@"
  '';
  home.file.".local/bin/fuzzel-focused".executable = true;

  home.file.".local/bin/fuzzel-launch".text = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    if [[ $# -eq 0 ]]; then
      exit 0
    fi

    # HP-OS owns a private compositor and D-Bus session. A user service
    # would replace this environment with the shared manager's environment.
    if [[ "''${HP_OS_OWNED_SESSION:-}" == 1 ]]; then
      exec "$@"
    fi

    unit="fuzzel-launched-$(${pkgs.coreutils}/bin/date +%s%N)-$RANDOM"
    exec ${pkgs.systemd}/bin/systemd-run \
      --user \
      --collect \
      --quiet \
      --same-dir \
      --unit="$unit" \
      -- "$@"
  '';
  home.file.".local/bin/fuzzel-launch".executable = true;

  home.file.".local/bin/screenshot-copy".text = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    mode="''${1:-area}"
    screenshot_dir="''${XDG_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}"
    mkdir -p "$screenshot_dir"
    file="$screenshot_dir/Screenshot from $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H-%M-%S').png"

    # The notification says where the screenshot went. Clicking it, or Show in Folder, opens the
    # Screenshots folder with this one selected; Open shows the picture. It stops listening after
    # 15 minutes, so nothing is left running.
    notify_saved() {
      where="''${screenshot_dir#"$HOME"/}"
      uri="$(${pkgs.python3}/bin/python3 -Ic 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$file")" || return 0
      (
        choice="$(${pkgs.coreutils}/bin/timeout 900 ${pkgs.libnotify}/bin/notify-send -a Screenshot -i camera-photo --wait \
          --action=default="Show in Folder" --action=reveal="Show in Folder" --action=open=Open \
          "Screenshot copied" "Saved in ''${where//\// › }")" || exit 0
        case "$choice" in
          default|reveal)
            ${pkgs.dbus}/bin/dbus-send --session --print-reply --type=method_call --dest=org.freedesktop.FileManager1 \
              /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems "array:string:$uri" "string:" ;;
          open) ${pkgs.xdg-utils}/bin/xdg-open "$file" ;;
        esac
      ) </dev/null >/dev/null 2>&1 &
    }

    copy_file() {
      ${pkgs.wl-clipboard}/bin/wl-copy --type image/png < "$file"
      notify_saved
    }

    case "$mode" in
      area)
        geometry="$(${pkgs.slurp}/bin/slurp)" || exit 0
        ${pkgs.grim}/bin/grim -g "$geometry" "$file"
        copy_file
        ;;
      screen)
        ${pkgs.grim}/bin/grim "$file"
        copy_file
        ;;
      window)
        ${pkgs.niri}/bin/niri msg action screenshot-window --write-to-disk true --show-pointer false --path "$file"
        notify_saved
        ;;
      *)
        echo "usage: screenshot-copy {area|screen|window}" >&2
        exit 2
        ;;
    esac
  '';
  home.file.".local/bin/screenshot-copy".executable = true;

}
