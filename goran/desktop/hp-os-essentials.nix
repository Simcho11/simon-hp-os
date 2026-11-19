# What every HP-OS account needs to work, and no apps: the only apps people start with are the
# Microsoft 365 web apps (microsoft365-standard.nix), beside HP-OS's own Files, Settings and Trash.
{ config, lib, pkgs, ... }:
{
  home.packages = with pkgs; [
    grim slurp wl-clipboard wl-clip-persist cliphist libnotify playerctl brightnessctl
    desktop-file-utils xdg-utils imagemagick ffmpegthumbnailer
    ghostty google-chrome   # every HP-OS account gets a terminal and Google Chrome
    fcitx5 fcitx5-rime hunspell hunspellDicts.en_US
    nerd-fonts.jetbrains-mono noto-fonts noto-fonts-cjk-sans noto-fonts-cjk-serif noto-fonts-color-emoji
  ];
  fonts.fontconfig.enable = true;

  # No extra apps or wallpaper collection: just the light and dark wallpapers (hp-snap/home.nix).
  programs.hp-os-fleet.enable = false;

  systemd.user.services.fcitx5 = {
    Unit = {
      Description = "Fcitx5 input method in the HP-OS session";
      PartOf = [ "goran-niri.target" ];
      After = [ "goran-niri.target" ];
    };
    Service = {
      ExecStart = "${pkgs.fcitx5}/bin/fcitx5 --replace";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [ "PATH=%h/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin" ];
    };
    Install.WantedBy = [ "goran-niri.target" ];
  };
  systemd.user.services.wl-clip-persist = {
    Unit = {
      Description = "Persist the Wayland clipboard";
      PartOf = [ "goran-niri.target" ];
      After = [ "goran-niri.target" ];
    };
    Service = {
      ExecStart = "${pkgs.wl-clip-persist}/bin/wl-clip-persist --clipboard both --write-timeout 5000 --reconnect-tries INF";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "goran-niri.target" ];
  };

  # Web links open in the browser behind the Microsoft 365 apps.
  xdg.mimeApps = {
    enable = true;
    defaultApplications = lib.genAttrs [ "text/html" "x-scheme-handler/http" "x-scheme-handler/https" "x-scheme-handler/about" "x-scheme-handler/unknown" ]
      (_: [ "hp-os-web.desktop" ]);
  };
}
