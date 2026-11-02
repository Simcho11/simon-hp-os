{ config, lib, pkgs, ... }:
# Simon's local changes, kept in this one file so published updates merge cleanly.
#
# One Chrome for everything: Simon's normal signed-in profile, with this desktop's
# hardware video decoding, and the GTK 4 path so windows get minimize, maximize
# and close. Every Microsoft 365 app from the shared catalogue, the Office
# document opener and plain Chrome start it. Desktop shortcuts are opt-in.
let
  catalogue = builtins.fromJSON (builtins.readFile ../desktop/microsoft365-webapps/apps.json);
  desktopDir = if config.xdg.userDirs.desktop != null then config.xdg.userDirs.desktop else "${config.home.homeDirectory}/Desktop";

  chrome = pkgs.writeShellScript "simon-chrome" ''
    set -euo pipefail
    # Always the normal profile. Apps started from the file manager inherit HP-OS's
    # file-manager-only XDG_CONFIG_HOME, and Chrome keeps its profile there.
    export XDG_CONFIG_HOME="$HOME/.config"
    # Use the Nix VA-API driver with Nix Chrome. Ubuntu's driver depends on
    # libraries outside Chrome's Nix loader search path.
    export LIBVA_DRIVER_NAME=nvidia
    export LIBVA_DRIVERS_PATH=${pkgs.nvidia-vaapi-driver}/lib/dri
    export NVD_BACKEND=direct
    # --gtk-version=4: only Chrome's GTK 4 path reads this desktop's button layout
    # (minimize, maximize, close). Chrome is one process per profile, so these flags
    # apply when it is the first Chrome window to start.
    exec ${pkgs.google-chrome}/bin/google-chrome-stable \
      --ozone-platform=wayland --gtk-version=4 \
      --enable-features=AcceleratedVideoDecodeLinuxGL,VaapiOnNvidiaGPUs,VaapiIgnoreDriverChecks,PlatformHEVCDecoderSupport \
      --ignore-gpu-blocklist --use-gl=angle --use-angle=gl "$@"
  '';

  # Outlook Calendar is not in the shared catalogue; add it the same way.
  calendar = pkgs.makeDesktopItem {
    name = "microsoft365-calendar";
    desktopName = "Microsoft Outlook Calendar";
    genericName = "Microsoft 365 Web App";
    comment = "Outlook Calendar in your Microsoft 365 Chrome session";
    exec = ''"${config.home.homeDirectory}/.local/bin/chrome-live-control" --app=https://outlook.cloud.microsoft/calendar/'';
    icon = "${./simon-local/calendar.svg}";
    terminal = false;
    categories = [ "Office" ];
    keywords = [ "Microsoft" "Microsoft 365" "Office 365" "calendar" "meetings" ];
    extraConfig = {
      StartupWMClass = "chrome-outlook.cloud.microsoft__calendar_-Default";
      "X-HP-OS-AppGroup" = "Microsoft 365";
      "X-HP-OS-WebApp-URL" = "https://outlook.cloud.microsoft/calendar/";
    };
  };
in {
  xdg.dataFile."applications/microsoft365-calendar.desktop".source =
    "${calendar}/share/applications/microsoft365-calendar.desktop";

  home.file = {
    # The catalogue keeps its launcher path and now gets this Chrome. The published
    # chrome-live-control used a separate profile and an always-on remote-debugging port.
    ".local/bin/chrome-live-control".source = lib.mkForce chrome;
    ".local/bin/simon-chrome" = { source = chrome; executable = true; };
  }
  # Desktop shortcut files for the catalogue are opt-in; the apps stay in the launcher
  # and Search. HP-OS's desktop icons come from its own layout, not this folder.
  // lib.listToAttrs (map (app: {
    name = "${desktopDir}/${app.name}.desktop";
    value.enable = false;
  }) catalogue);
}
