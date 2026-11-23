# Per-user hp-snap pieces that used to be set up by hand in Simon's home folder, for accounts with
# programs.goran-hp-os.hpSnap.enable (the shell, niri and launcher changes are in ./default.nix).
{ config, lib, pkgs, hp-os, ... }:
let
  enabled = config.programs.goran-hp-os.enable && config.programs.goran-hp-os.hpSnap.enable;
  niriDir = "${config.xdg.configHome}/hp-os/niri";
  appTheme = "${pkgs.python3}/bin/python3 ${./app-theme/sync.py}";

  wallpapers = import ./wallpapers.nix { inherit pkgs; };
  wallpaperDir = "${config.home.homeDirectory}/Pictures/Wallpapers/HP-OS";
  lightWallpaper = "${wallpaperDir}/hp-os-daybreak.png";
  darkWallpaper = "${wallpaperDir}/hp-os-harmony-night.png";
  followMode = "${pkgs.python3}/bin/python3 ${./wallpaper/follow-mode.py} ${lib.escapeShellArg lightWallpaper} ${lib.escapeShellArg darkWallpaper}";
  buttons = ":minimize,maximize,close";

  # Window snapping: layouts, Super+arrows and drag-to-edge (./snap-app).
  quickshell = hp-os.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.quickshell;
  snapDaemon = pkgs.writeShellScript "hp-snap-daemon" ''
    rm -f "''${XDG_RUNTIME_DIR:?}/hp-snap.sock"
    exec ${quickshell}/bin/quickshell -n -p ${./snap-app}
  '';
  # Settings' touchpad feedback and click pressure.
  touchpadHaptics = pkgs.writeScript "touchpad-haptics"
    ("#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./touchpad-haptics.py);
  # AirDrop is published for every account by goran/installer/system/hp-os-settings-access.sh.
  airdrop = "/nix/var/nix/profiles/hp-os-airdrop/share/omdrop";
  airdropSetup = pkgs.writeShellScript "hp-os-airdrop-setup" ''
    [[ -r ${airdrop}/OmdropPanel.qml ]] || exit 0
    cli=$(${pkgs.gnused}/bin/sed -n 's/.*property string cli: "\(.*\)".*/\1/p' ${airdrop}/OmdropPanel.qml)
    exec "$cli" setup
  '';
  snapCommand = pkgs.writeShellScript "hp-snap" ''
    printf '%s\n' "$*" | ${pkgs.netcat-openbsd}/bin/nc -UN "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hp-snap.sock"
  '';
in {
  config = lib.mkIf enabled (lib.mkMerge [
  {
    # A downloaded app's .deb file opens in App Installer (the system's launcher for it, from hp-os-add-user.sh),
    # not in Archive Manager, which only showed what's inside. Low priority: an account's own choice wins.
    xdg.mimeApps.defaultApplications = lib.genAttrs
      [ "application/vnd.debian.binary-package" "application/x-deb" "application/x-debian-package" ]
      (_: lib.mkOverride 900 [ "hp-os-app-installer.desktop" ]);
  }
  (lib.mkIf config.programs.goran-hp-os.hpSnap.manageHouseDefaults {
    # The niri settings hp-snap's shell relies on (from Simon's config.d/50-startup.kdl, without
    # his personal entries). Without the layer rule, the Applications view's blur never clears.
    xdg.configFile."hp-os/niri/config.d/49-hp-snap.kdl".text = ''
      // Managed by Home Manager (goran/desktop/hp-snap/home.nix).
      // Files the shell and launcher rewrite at runtime (created empty at activation).
      include "48-boot-cursor.kdl"
      include "47-unlock-zoom.kdl"
      include "46-accent.kdl"

      // Qt draws the title bars for HP-OS Settings and Dolphin under Niri.
      environment {
          QT_WAYLAND_DECORATION "adwaita"
      }

      // Tell systemd where the display is, so services it starts can open windows.
      spawn-at-startup "dbus-update-activation-environment" "--systemd" "WAYLAND_DISPLAY" "DISPLAY" "XDG_CURRENT_DESKTOP" "XDG_SESSION_DESKTOP" "XDG_SESSION_TYPE"

      // Open every new window floating, like a traditional desktop. Super+V switches it to tiling.
      window-rule {
          open-floating true
      }

      // Microsoft 365 web apps (Chrome --app windows) open at a normal landscape size.
      window-rule {
          match app-id=r#"^chrome-.*-Default$"#
          default-column-width { fixed 1280; }
          default-window-height { fixed 880; }
      }

      // The ChatGPT app asks for a window far larger than the screen.
      window-rule {
          match app-id=r#"^(?i)chatgpt$"#
          default-column-width { fixed 1280; }
          default-window-height { fixed 880; }
      }

      // The Applications view draws its own blurred wallpaper and fades it out above the Dock;
      // niri's blur behind it (HP-OS's "^harmony" layer rule) would hide that fade.
      layer-rule {
          match namespace="^(hpos|hpos)-application-center$"
          background-effect { blur false; xray false; }
      }

      // Black instead of niri's gray behind everything until the shell's wallpaper is up.
      layout {
          background-color "#000000"
      }

      // Window snapping. Its keys live in config.kdl's own binds (login-backdrop.py), because HP-OS's
      // binding sync refuses to run when an included file binds the same keys.
      spawn-at-startup "${snapDaemon}"
    '';
    home.file.".local/share/hp-os/bin/hp-snap".source = snapCommand;

    home.activation.hpSnapNiri = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run mkdir -p ${lib.escapeShellArg "${niriDir}/config.d"}
      for file in 46-accent.kdl 47-unlock-zoom.kdl 48-boot-cursor.kdl; do
        target=${lib.escapeShellArg "${niriDir}/config.d"}/$file
        [[ -e "$target" ]] || run ${pkgs.coreutils}/bin/touch "$target"
      done
      main=${lib.escapeShellArg "${niriDir}/config.kdl"}
      if [[ -f "$main" ]] && ! ${pkgs.gnugrep}/bin/grep -qxF 'include "config.d/49-hp-snap.kdl"' "$main"; then
        run ${pkgs.bash}/bin/bash -c 'printf "\ninclude \"config.d/49-hp-snap.kdl\"\n" >> "$1"' _ "$main"
      fi
    '';

    # House defaults (dock: Files, Trash, Settings; simple Settings in a window) for an account
    # that already has a config. Once per account; new accounts get them from the default config.
    home.activation.hpSnapDefaults = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./defaults.json} \
        ${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-defaults-v4"}
    '';
    # A desktop HP-OS already seeded off the grid (before the fix in hp-os.nix): onto the grid, once.
    home.activation.hpSnapDesktopGrid = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.python3}/bin/python3 ${./snap-desktop.py} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/user/desktop-items.json"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-desktop-grid-v1"}
    '';

    # Light and dark wallpapers; the wallpaper follows light/dark (followMode, below).
    home.file."Pictures/Wallpapers/HP-OS/hp-os-daybreak.png".source = "${wallpapers}/hp-os-daybreak.png";
    home.file."Pictures/Wallpapers/HP-OS/hp-os-harmony-night.png".source = "${wallpapers}/hp-os-harmony-night.png";

    # GTK/Qt apps follow the shell's light/dark, accent and font (writes gtk-*/dank-colors.css),
    # and the wallpaper follows light/dark.
    systemd.user.services.hp-os-app-theme = {
      Unit.Description = "Sync GTK and Qt application themes and the wallpaper with the HP-OS shell";
      # Settings can save config.json several times a second. With systemd's default start limit
      # (5 starts in 10 s) such a burst would stop the watcher below for the rest of the session.
      Unit.StartLimitIntervalSec = 0;
      Service = { Type = "oneshot"; ExecStart = [ appTheme followMode ]; };
      Install.WantedBy = [ "default.target" ];
    };
    home.activation.hpSnapWallpaper = lib.hm.dag.entryAfter [ "linkGeneration" "hpSnapDefaults" ] ''
      run ${followMode} || true
    '';
    systemd.user.paths.hp-os-app-theme = {
      Unit.Description = "Watch HP-OS light/dark and accent changes";
      Path.PathChanged = [ "%h/.local/state/hp-os/appearance-mode" "%h/.config/hp-os/config.json" ];
      Install.WantedBy = [ "default.target" ];
    };
    home.activation.hpOsAppTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${appTheme} || true
    '';

    # The GNOME portal (screen sharing, and the Settings portal that tells apps their title-bar
    # buttons) cannot start in HP-OS: Ubuntu's unit requires graphical-session.target, which HP-OS
    # never starts. Simon's own fix (2026-11-02): the same unit without Requisite=/PartOf=.
    xdg.configFile."systemd/user/xdg-desktop-portal-gnome.service".text = ''
      # Managed by Home Manager (goran/desktop/hp-snap/home.nix): Ubuntu's unit without
      # Requisite=/PartOf=graphical-session.target, which HP-OS never starts.
      [Unit]
      Description=Portal service (GNOME implementation)
      After=graphical-session.target

      [Service]
      Type=dbus
      BusName=org.freedesktop.impl.portal.desktop.gnome
      ExecStart=/usr/libexec/xdg-desktop-portal-gnome
    '';
  })
  {
    home.activation.hpSnapGlassTray = lib.hm.dag.entryAfter [ "hpOsDesktopControls" "linkGeneration" ] ''
      run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./glass-and-tray.json} \
        ${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-glass-tray-v2"}
    '';
    # Windows Office apps open beside the other desktop apps, on every account (included by
    # login-backdrop.py). The desktop-switching shortcuts reach HP-OS from ../niri.nix.
    # The same file carries the rule for HP-OS's own glass windows, being already in every account's niri settings
    # (a new file would need a new include, which a switch back to an earlier version would leave pointing nowhere).
    xdg.configFile."hp-os/niri/config.d/64-hp-office.kdl".text = ''
      // Managed by Home Manager (goran/desktop/hp-snap/home.nix).
      window-rule {
          match app-id="^hp-office-(powerpoint|word|excel|setup)$" title=".+"
          open-floating true
          default-column-width { fixed 1300; }
          default-window-height { fixed 900; }
      }
      // App Installer and Software Update are panes of glass: what is behind them shows through, other windows
      // included, as through the desktop's own glass (niri's default for a window shows the wallpaper alone).
      window-rule {
          match app-id=r#"^org\.quickshell$"# title=r#"^(App Installer|Software Update)$"#
          background-effect { xray false; }
      }
    '';
    # Commands the shell's settings call: the icon theme for KDE apps and the on-screen keyboard.
    home.packages = [ pkgs.kdePackages.kconfig pkgs.ydotool ];
    # Touchpad feedback and click pressure. An account that already has the tool keeps its own.
    home.activation.hpSnapTouchpadHaptics = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/hp-snap/bin/touchpad-haptics"}
      if [[ ! -e "$target" ]]; then
        run mkdir -p "$(dirname "$target")"
        run ln -sfn ${touchpadHaptics} "$target"
      fi
    '';
    # The AirDrop tile. An account that already has AirDrop keeps its own.
    home.activation.hpSnapAirdrop = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${lib.escapeShellArg "${config.xdg.configHome}/hp-os/omdrop"}
      if [[ ! -e "$target" && -r ${airdrop}/OmdropPanel.qml ]]; then
        run mkdir -p "$(dirname "$target")"
        run ln -sfn ${airdrop} "$target"
      fi
    '';
    # AirDrop's per-account pieces (its certificate and receiver), once. Exits straight away afterwards.
    systemd.user.services.hp-os-airdrop-setup = {
      Unit = {
        Description = "Prepare AirDrop for this account";
        ConditionPathExists = "!%h/.config/systemd/user/airdrop-receiver.service";
      };
      Service = { Type = "oneshot"; ExecStart = "${airdropSetup}"; };
      Install.WantedBy = [ "default.target" ];
    };
    # Windows use the whole screen above the Dock: small edge widgets don't reserve a strip beside them.
    home.activation.hpSnapWindowSpace = lib.hm.dag.entryAfter [ "hpSnapGlassTray" ] ''
      run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./window-space.json} \
        ${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-window-space-v1"}
    '';
    # HP blue is the system accent, once per account, for accounts still on the stock accent (one someone chose stays).
    home.activation.hpSnapHpBlue = lib.hm.dag.entryAfter [ "hpSnapGlassTray" ] ''
      config=${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"}
      if [ -f "$config" ] && ${pkgs.python3}/bin/python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("iris",{}).get("appearance",{}); sys.exit(0 if a.get("accent","blue") in ("blue","") else 1)' "$config"; then
        run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./hp-blue-accent.json} "$config" \
          ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-hp-blue-v1"}
      fi
    '';
    # Wallpaper shuffle is out of HP-OS for now: switched off once on accounts that had it on.
    home.activation.hpSnapNoShuffle = lib.hm.dag.entryAfter [ "hpSnapGlassTray" ] ''
      run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./no-shuffle.json} \
        ${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-no-shuffle-v1"}
    '';
    # The terminal HP-OS ships (Ghostty), once per account still set to the stock kitty, which HP-OS doesn't have.
    home.activation.hpSnapTerminal = lib.hm.dag.entryAfter [ "hpSnapGlassTray" ] ''
      config=${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"}
      if [ -f "$config" ] && ${pkgs.python3}/bin/python3 -c 'import json,sys; t=json.load(open(sys.argv[1])).get("apps",{}).get("terminal","kitty"); sys.exit(0 if t in ("kitty","") else 1)' "$config"; then
        run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./terminal.json} "$config" \
          ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-terminal-v1"}
      fi
    '';
    # The HP-OS User Guide: always at ~/.local/share/hp-os (Settings › Welcome opens it), and on the desktop. The
    # desktop copy is put there once; a later edition replaces it only while it is the copy put there, so a guide
    # that was moved, changed or deleted stays that way.
    home.file.".local/share/hp-os/HP-OS User Guide.pdf".source = ../../docs/user-guide/hp-os-user-guide.pdf;
    home.activation.hpOsUserGuide = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      desktop=${lib.escapeShellArg (if config.xdg.userDirs.desktop != null then config.xdg.userDirs.desktop else "${config.home.homeDirectory}/Desktop")}
      guide="$desktop/HP-OS User Guide.pdf"
      mark=${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/user-guide-on-desktop"}
      new=${../../docs/user-guide/hp-os-user-guide.pdf}
      wanted=$(sha256sum "$new" | cut -d' ' -f1)
      if [ ! -e "$mark" ]; then
        if [ ! -e "$guide" ]; then
          run mkdir -p "$desktop"
          run install -m 644 "$new" "$guide"
        fi
        run mkdir -p "$(dirname "$mark")"
        [ -n "''${DRY_RUN:-}" ] || echo "$wanted" > "$mark"
      elif [ -f "$guide" ] && [ "$(sha256sum "$guide" | cut -d' ' -f1)" = "$(cat "$mark")" ] && [ "$wanted" != "$(cat "$mark")" ]; then
        run install -m 644 "$new" "$guide"
        [ -n "''${DRY_RUN:-}" ] || echo "$wanted" > "$mark"
      fi
    '';
    # The plate marking where a dragged icon will land starts off, once per account (Settings > Desktop turns it on).
    home.activation.hpSnapDropSlotOff = lib.hm.dag.entryAfter [ "hpSnapGlassTray" ] ''
      run ${pkgs.python3}/bin/python3 ${./apply-defaults.py} ${./drop-slot-off.json} \
        ${lib.escapeShellArg "${config.xdg.configHome}/hp-os/config.json"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-drop-slot-off-v1"}
    '';
    # Niri's Liquid Glass settings, as tuned on Simon's account: glass blurs what is really behind
    # it (xray off), so it stays right while desktops scroll, plus his blur block. New accounts get
    # the same from HP-OS's starting niri.kdl (hp-os.nix).
    home.activation.hpSnapNiriBlur = lib.hm.dag.entryAfter [ "linkGeneration" "hposNiriBindings" ] ''
      run ${pkgs.python3}/bin/python3 ${./glass-niri.py} ${lib.escapeShellArg "${niriDir}/config.kdl"}
    '';
    # No window outline and HarmonyOS's soft shadows, once per account (Settings can change them later).
    home.activation.hpSnapWindowStyle = lib.hm.dag.entryAfter [ "linkGeneration" "hposNiriBindings" ] ''
      run ${pkgs.python3}/bin/python3 ${./window-style.py} ${lib.escapeShellArg "${niriDir}/config.kdl"} \
        ${lib.escapeShellArg "${config.xdg.stateHome}/hp-os/hp-snap-window-style-v1"}
    '';
    # An account that runs its own hand-installed snap app gets the same window handling.
    home.activation.hpSnapEngine = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/hp-snap/lib/engine.mjs"}
      if [[ -f "$target" ]]; then
        run ${pkgs.coreutils}/bin/install -m 644 ${./snap-app/lib/engine.mjs} "$target"
      fi
    '';
    # Minimize, maximize and close on every window (GTK 3/4 and libadwaita read different places).
    gtk.gtk3.extraConfig.gtk-decoration-layout = buttons;
    gtk.gtk4.extraConfig.gtk-decoration-layout = buttons;
    dconf.settings."org/gnome/desktop/wm/preferences".button-layout = buttons;
    # HP-OS's Nix-built apps read GLib's keyfile, not dconf: without this they get no buttons.
    home.activation.hpSnapButtons = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.python3}/bin/python3 ${./app-theme/buttons.py} ${lib.escapeShellArg buttons}
    '';
  }
  ]);
}
