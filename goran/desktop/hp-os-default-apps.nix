# One set of default apps for every HP-OS account, the same on every device.
#
#   Pictures   Image Viewer (Loupe)          Videos and music  Celluloid
#   Documents  Document Viewer (Papers)      Archives          Archive Manager (File Roller)
#   Text       Text Editor
#
# The apps come from Nix, so x86 devices (whose Ubuntu has none of them) get them
# too. Their launchers are placed in ~/.local/share/applications, which the HP-OS
# app list and every "open with" search, run the Nix build directly (not a copy
# Ubuntu may have), and start it with the file rather than over D-Bus.
#
# Each file type is a default at low priority: an account's own choice (Simon's
# Emacs for text, Chrome for PDFs) wins. The user's own choices live in
# ~/.config/hp-os-mimeapps.list, which default-apps/migrate.py keeps usable.
{ config, lib, pkgs, ... }:
let
  types = builtins.fromJSON (builtins.readFile ./default-apps/mime-types.json);
  # HP-OS's icon theme draws the Photos icon; the others use the app's own icon file.
  apps = {
    images = { package = pkgs.loupe; id = "org.gnome.Loupe"; program = "loupe"; themedIcon = true; };
    documents = { package = pkgs.papers; id = "org.gnome.Papers"; program = "papers"; themedIcon = false; };
    text = { package = pkgs.gnome-text-editor; id = "org.gnome.TextEditor"; program = "gnome-text-editor"; themedIcon = false; };
    media = { package = pkgs.celluloid; id = "io.github.celluloid_player.Celluloid"; program = "celluloid"; themedIcon = false; };
    archives = { package = pkgs.file-roller; id = "org.gnome.FileRoller"; program = "file-roller"; themedIcon = false; };
  };
  extraLauncher = name: app: launcher name (app // { themedIcon = app.themedIcon or false; });
  # Thumbnailers from Nix, like the apps: PDFs and comics (Papers) and videos (ffmpegthumbnailer).
  # The desktop, and GNOME apps, look in ~/.local/share/thumbnailers before Ubuntu's own, which
  # may be missing (x86) or broken (Ubuntu's papers-thumbnailer fails on this ARM build).
  thumbnailers = pkgs.runCommand "hp-os-thumbnailers" { } ''
    mkdir -p "$out"
    for file in ${pkgs.papers}/share/thumbnailers/*.thumbnailer ${pkgs.ffmpegthumbnailer}/share/thumbnailers/*.thumbnailer; do
      grep -q '^TryExec=/nix/store/' "$file" || { echo "$file: its program is not a full path" >&2; exit 1; }
      cp "$file" "$out/hp-os-$(basename "$file")"
    done
  '';
  launcher = kind: app: pkgs.runCommand "hp-os-${kind}-app-${app.id}" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${./default-apps/launcher.py} \
      --entry ${app.package}/share/applications/${app.id}.desktop \
      --program ${app.package}/bin/${app.program} \
      --share ${app.package}/share \
      ${lib.optionalString (!app.themedIcon) "--icon-file"} \
      --types ${lib.escapeShellArg (lib.concatStringsSep ";" (app.types or types.${kind}))} \
      --out "$out/${app.id}.desktop"
  '';
in {
  # An account's own default app from its Nix profile, made visible the same way
  # (the HP-OS session does not search the profile's launchers). Each value:
  # { package; id; program; types = [ mime types it is the default for ]; }
  options.programs.goran-hp-os.defaultApps.extraLaunchers = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = { };
    description = "Account-specific default apps to list in ~/.local/share/applications.";
  };

  config = lib.mkIf config.programs.goran-hp-os.enable {
    xdg.mimeApps.enable = true;
    xdg.mimeApps.defaultApplications = lib.mkMerge (lib.mapAttrsToList (kind: app:
      lib.genAttrs types.${kind} (_: lib.mkDefault [ "${app.id}.desktop" ])) apps);

    xdg.dataFile = lib.mapAttrs' (kind: app: lib.nameValuePair "applications/${app.id}.desktop" {
      source = "${launcher kind app}/${app.id}.desktop";
    }) apps // lib.mapAttrs' (name: app: lib.nameValuePair "applications/${app.id}.desktop" {
      source = "${extraLauncher name app}/${app.id}.desktop";
    }) config.programs.goran-hp-os.defaultApps.extraLaunchers // {
      "thumbnailers" = { source = thumbnailers; recursive = true; };
      # Gwenview comes with the shell's data folders but isn't installed as a program,
      # so its tile and "Open with" entry could only fail. Image Viewer replaces it.
      "applications/org.kde.gwenview.desktop".text = ''
        [Desktop Entry]
        Type=Application
        Name=Gwenview
        Hidden=true
      '';
    };

    # Keep the user's own choices usable: drop "defaults" that cannot open a file,
    # share Files' "Open with" choices with every app, and keep a choice an app
    # saved over the managed list. Everything replaced is set aside, not deleted.
    home.activation.hpOsDefaultApps = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      run ${pkgs.python3}/bin/python3 ${./default-apps/migrate.py} \
        --config-home ${lib.escapeShellArg config.xdg.configHome} \
        --files-profile ${lib.escapeShellArg "${config.xdg.configHome}/hp-os/apps/files"} \
        --migration ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/files-migration"} \
        --managed "$newGenPath/home-files/.config/mimeapps.list" \
        --managed-copy ${lib.escapeShellArg "${config.xdg.dataHome}/applications/mimeapps.list"} \
        --applications "$newGenPath/home-files/.local/share/applications" \
        --applications ${lib.escapeShellArg "${config.xdg.dataHome}/applications"} \
        --applications "$newGenPath/home-path/share/applications" \
        --applications ${config.programs.hp-os.package}/share/hp-os/applications \
        --applications ${config.programs.hp-os.package}/share/applications \
        --applications /usr/local/share/applications \
        --applications /usr/share/applications \
        --applications /var/lib/flatpak/exports/share/applications \
        --applications ${lib.escapeShellArg "${config.xdg.dataHome}/flatpak/exports/share/applications"}
    '';
  };
}
