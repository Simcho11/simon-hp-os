# A plain HP-OS account on this machine: the shared desktop, none of Simon's personal setup.
# flake.lib.hpOsAccount builds this for any standard account.
# Apply with:  sudo goran/installer/hp-os-user-apply.sh USERNAME
username:
{ config, lib, pkgs, ... }:
{
  home.username = username;
  home.homeDirectory = "/home/${username}";
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  programs.goran-hp-os.enable = true;
  # The same patched niri, xwayland-satellite and shell Simon's desktop runs (goran/desktop/hp-snap).
  # No every-minute sunrise/sunset switching: it overrode a hand-picked dark mode. Light by
  # default (hp-snap/defaults.json), and the wallpaper follows whatever mode the user picks.
  programs.goran-hp-os.appearanceSchedule.enable = false;

  # Same GPU userspace as Simon's account; Nix-built apps need it to draw on the NVIDIA GPU.
  targets.genericLinux.gpu = {
    enable = true;
    # Only the ARM OmniBook has this NVIDIA chip. x86 laptops use the standard open graphics drivers.
    nvidia = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
      enable = true;
      version = "615.78.08";
      sha256 = "sha256-UHYBE1AYHoGgMfD9AS/jX+S+N8eCDWUft6qolK9Eejc=";
    };
  };

  # Upscayl's AppArmor rule is system-wide and its activation step needs passwordless sudo,
  # which these accounts don't have (it stopped activation). Install the rule once as an admin.
  home.activation.upscaylSandbox = lib.mkForce (lib.hm.dag.entryAfter [ "writeBoundary" ] "");

  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };
}
