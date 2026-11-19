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
  # Opens web links. It is the engine behind the web apps, so it isn't listed as an app of its own.
  web = pkgs.makeDesktopItem {
    name = "hp-os-web";
    desktopName = "Web";
    exec = ''"${launcher}" %U'';
    noDisplay = true;
    mimeTypes = [ "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
  };
  # Everything else that arrives with the desktop's own parts stays out of the app list.
  shown = [ "org.kde.dolphin" "hp-os-settings" "hp-os-trash" "com.mitchellh.ghostty" "google-chrome" ];
  hidden = pkgs.runCommand "hp-os-hidden-apps" { } ''
    mkdir -p "$out"
    for file in ${config.home.path}/share/applications/*.desktop; do
      name=$(basename "$file")
      case " ${lib.concatStringsSep " " shown} " in *" ''${name%.desktop} "*) continue ;; esac
      case "$name" in microsoft365-*|hp-os-web.desktop) continue ;; esac
      printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' "''${name%.desktop}" > "$out/$name"
    done
  '';
  # The app list only searches ~/.local/share and the system folders, not the account's Nix profile, so the
  # apps installed for every account are listed there too, each with its icon as a file so it always shows.
  listed = [ "com.mitchellh.ghostty" "google-chrome" ];
  listedApps = pkgs.runCommand "hp-os-listed-apps" { } ''
    mkdir -p "$out"
    for id in ${lib.concatStringsSep " " listed}; do
      entry=${config.home.path}/share/applications/$id.desktop
      [ -f "$entry" ] || { echo "missing $entry" >&2; exit 1; }
      icon=$(sed -n 's/^Icon=//p' "$entry" | head -n 1)
      found=""
      for candidate in scalable/apps/$icon.svg 512x512/apps/$icon.png 256x256/apps/$icon.png 128x128/apps/$icon.png; do
        if [ -f ${config.home.path}/share/icons/hicolor/$candidate ]; then
          found=$(readlink -f ${config.home.path}/share/icons/hicolor/$candidate); break
        fi
      done
      if [ -n "$found" ]; then sed "s|^Icon=.*|Icon=$found|" "$entry" > "$out/$id.desktop"; else cp "$entry" "$out/$id.desktop"; fi
    done
  '';
in {
  home.file = {
    ".local/bin/chrome-live-control".source = chrome;
    # Google Chrome on every desktop, beside the Microsoft 365 folder.
    "${desktopDir}/Google Chrome.desktop" = { source = "${listedApps}/google-chrome.desktop"; executable = true; };
  } // builtins.listToAttrs (map (app: {
    name = "${desktopDir}/Microsoft 365/${folder.${app.id}}.desktop";
    value = { source = file app; executable = true; };
  }) (builtins.filter (app: folder ? ${app.id}) catalogue));
  xdg.dataFile = {
    "applications/hp-os-web.desktop".source = "${web}/share/applications/hp-os-web.desktop";
  } // builtins.listToAttrs (map (app: {
    name = "applications/microsoft365-${app.id}.desktop";
    value.source = file app;
  }) catalogue) // builtins.listToAttrs (map (id: {
    name = "applications/${id}.desktop";
    value.source = "${listedApps}/${id}.desktop";
  }) listed);
  home.activation.hpOsHiddenApps = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run mkdir -p ${lib.escapeShellArg "${config.xdg.dataHome}/applications"}
    for file in ${hidden}/*.desktop; do
      run ln -sf "$file" ${lib.escapeShellArg "${config.xdg.dataHome}/applications"}/
    done
  '';
}
