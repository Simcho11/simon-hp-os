# Microsoft 365 for every HP-OS account: all the web apps in the app launcher, and the everyday
# ones in a Microsoft 365 folder on the desktop. Word, Excel and PowerPoint are web apps here too.
{ config, lib, pkgs, ... }:
let
  catalogue = builtins.fromJSON (builtins.readFile ./microsoft365-webapps/apps.json);
  launcher = "${config.home.homeDirectory}/.local/bin/chrome-live-control";
  desktopDir = if config.xdg.userDirs.desktop != null then config.xdg.userDirs.desktop else "${config.home.homeDirectory}/Desktop";
  folder = { hub = "Microsoft 365"; word = "Word"; excel = "Excel"; powerpoint = "PowerPoint"; outlook = "Outlook";
             teams = "Teams"; onedrive = "OneDrive"; sharepoint = "SharePoint"; };
  chrome = pkgs.writeShellScript "hp-os-chrome" ''
    set -euo pipefail
    export XDG_CONFIG_HOME="$HOME/.config"
    export LIBVA_DRIVER_NAME=nvidia
    export LIBVA_DRIVERS_PATH=${pkgs.nvidia-vaapi-driver}/lib/dri
    export NVD_BACKEND=direct
    exec ${pkgs.google-chrome}/bin/google-chrome-stable \
      --ozone-platform=wayland --gtk-version=4 \
      --enable-features=AcceleratedVideoDecodeLinuxGL,VaapiOnNvidiaGPUs,VaapiIgnoreDriverChecks,PlatformHEVCDecoderSupport \
      --ignore-gpu-blocklist --use-gl=angle --use-angle=gl "$@"
  '';
  windowClass = app:
    let parts = builtins.match "https://([^/]+)(/.*)" app.url;
    in "chrome-${lib.replaceStrings [ "/" ] [ "_" ] "${builtins.elemAt parts 0}_${builtins.elemAt parts 1}"}-Default";
  entry = app: pkgs.makeDesktopItem {
    name = "microsoft365-${app.id}";
    desktopName = app.name;
    genericName = "Microsoft 365 Web App";
    comment = "${app.name} on the web";
    exec = ''"${launcher}" --app=${app.url}'';
    icon = "${./microsoft365-webapps/icons}/${app.icon}";
    terminal = false;
    categories = [ "Office" ];
    keywords = [ "Microsoft" "Microsoft 365" "Office 365" ] ++ app.keywords;
    extraConfig = {
      StartupWMClass = windowClass app;
      "X-HP-OS-AppGroup" = "Microsoft 365";
      "X-HP-OS-WebApp-URL" = app.url;
    };
  };
  file = app: "${entry app}/share/applications/microsoft365-${app.id}.desktop";
in {
  home.packages = [ pkgs.google-chrome ];
  home.file = {
    ".local/bin/chrome-live-control".source = chrome;
  } // builtins.listToAttrs (map (app: {
    name = "${desktopDir}/Microsoft 365/${folder.${app.id}}.desktop";
    value = { source = file app; executable = true; };
  }) (builtins.filter (app: folder ? ${app.id}) catalogue));
  xdg.dataFile = builtins.listToAttrs (map (app: {
    name = "applications/microsoft365-${app.id}.desktop";
    value.source = file app;
  }) catalogue);
}
