{ source, system }:
let
  fleet = builtins.getFlake source;
  pkgs = import fleet.inputs.nixpkgs { inherit system; };
  home = fleet.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ ../fleet/native-pam/home.nix {
      home.username = "test";
      home.homeDirectory = "/home/test";
      home.stateVersion = "25.05";
      programs.hp-os-fleet.nativePam.enable = system == "aarch64-linux";
    } ];
  };
  gate = home.config.home.activation.verifyDesktopNativePam or null;
in
assert (gate != null) == (system == "aarch64-linux");
assert gate == null || builtins.elem "writeBoundary" gate.before;
{ inherit system; guarded = gate != null; }
