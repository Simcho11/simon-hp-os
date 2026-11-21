# Goran's Ubuntu/Niri equivalent of the shared fleet COSMIC app repair
# (COSMIC Terminal, Launcher and App Library; theme and settings watcher).
# HP-OS owns a separate session bus and portal configuration.
{ lib, pkgs, ... }:
let
  settingsDaemon = pkgs.callPackage ../../pkgs/cosmic-settings-daemon/package.nix {
    # COSMIC_SETTINGS_CONFIG_ONLY disables the battery monitor in this session.
    withBatterySounds = false;
  };
  portalGtk = pkgs.callPackage ../../pkgs/xdg-desktop-portal-gtk-network {
    portalGtk = pkgs.xdg-desktop-portal-gtk;
  };
  portalLauncher = pkgs.writeShellScript "goran-gtk-portal-session" ''
    if [ "''${XDG_CURRENT_DESKTOP:-}" = niri ]; then
      exec ${portalGtk}/libexec/xdg-desktop-portal-gtk
    fi
    exec /usr/libexec/xdg-desktop-portal-gtk
  '';
in {
  imports = [ ./cosmic-hp-os-theme.nix ];
  # Files is HP-OS Files (Dolphin) in every session; see hp-os.nix. COSMIC
  # Files is no longer installed. The COSMIC theme and settings watcher below
  # stay for COSMIC Terminal, Launcher and App Library.
  # HP-OS owns a private session bus, outside goran-niri.target. Let COSMIC
  # applications activate their config watcher on whichever bus they use.
  xdg.dataFile."dbus-1/services/com.system76.CosmicSettingsDaemon.service".text = ''
    [D-BUS Service]
    Name=com.system76.CosmicSettingsDaemon
    Exec=${pkgs.coreutils}/bin/env COSMIC_SETTINGS_CONFIG_ONLY=1 ${settingsDaemon}/bin/cosmic-settings-daemon
  '';
  xdg.configFile."systemd/user/xdg-desktop-portal-gtk.service.d/network.conf".text = ''
    [Service]
    ExecStart=
    ExecStart=${portalLauncher}
  '';
  systemd.user.services.cosmic-settings-daemon = {
    Unit = {
      Description = "COSMIC app configuration watcher for Goran Niri";
      PartOf = [ "goran-niri.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = [ "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/.config/cosmic %h/.local/state/cosmic";
      ExecStart = "${settingsDaemon}/bin/cosmic-settings-daemon";
      Environment = [ "COSMIC_SETTINGS_CONFIG_ONLY=1" ];
      Type = "dbus";
      BusName = "com.system76.CosmicSettingsDaemon";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "goran-niri.target" ];
  };
}
