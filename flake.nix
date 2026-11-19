{
  description = "Simon HP-OS desktop for Ubuntu 26.04 ARM64";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = { url = "github:nix-community/home-manager"; inputs.nixpkgs.follows = "nixpkgs"; };
    hp-os.url = "path:./vendor/HP-OSShell";
    codex-fleet = { url = "path:./vendor/codex-fleet"; inputs.nixpkgs.follows = "nixpkgs"; };
    ghostty-upstream.url = "github:ghostty-org/ghostty/ce787fc18a7782e81585beb63f0d905ccaf69284";
    dank-material-shell = { url = "github:AvengeMedia/DankMaterialShell/ef191babb72c83bf16254d3f9416e7b2e8ef61d6"; inputs.nixpkgs.follows = "nixpkgs"; };
    dms-plugin-registry = { url = "github:AvengeMedia/dms-plugin-registry/bd0adca992b502178e70cc015f2a34f2b7031186"; inputs.nixpkgs.follows = "nixpkgs"; };
    xwayland-satellite = { url = "github:Supreeeme/xwayland-satellite/8d135d3b2854b30fd01ea6cd6c27e523dd50a839"; inputs.nixpkgs.follows = "nixpkgs"; };
  };
  outputs = { self, nixpkgs, home-manager, hp-os, codex-fleet, ghostty-upstream, dank-material-shell, dms-plugin-registry, xwayland-satellite, ... }:
    let
      system = "aarch64-linux";
      ghosttyCpuPresentation = ghostty-upstream.packages.${system}.default.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./goran/desktop/ghostty-n1x-cpu-presentation.patch ];
      });
      pkgs = import nixpkgs {
        inherit system;
        config = { allowUnfree = true; nvidia.acceptLicense = true; };
        overlays = [
          (final: prev: { cloudflared = final.callPackage ./pkgs/cloudflared-release.nix { }; })
          codex-fleet.overlays.default
          (import ./goran/desktop/ghostty-overlay.nix { ghosttyPackage = ghosttyCpuPresentation; })
          (import ./goran/desktop/niri-hdr-overlay.nix)
        ];
      };
      standardHome = name: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit hp-os dank-material-shell dms-plugin-registry xwayland-satellite;
          n1xPersonalServices = false;
        };
        modules = [
          ./fleet/home.nix
          (import ./goran/installer/hp-os-user.nix name)
          ./goran/desktop/hp-os-essentials.nix
          ./goran/desktop/microsoft365-standard.nix
          ./goran/desktop/hp-os.nix
          ./goran/desktop/niri.nix
          ./goran/desktop/launchers.nix
          ./goran/desktop/dms.nix
          ./goran/desktop/power.nix
          ./goran/desktop/hp-os-theme.nix
        ];
      };
    in nixpkgs.lib.recursiveUpdate {
      # Used by the Ubuntu first-login installer for names that did not exist at build time.
      # Only Simon's own laptop gives the account "simon" his personal desktop. On a device made from the
      # USB installer (marked by /etc/hp-os/standard-device), anyone can use that name and get the shared one.
      lib.hpOsAccount = name:
        if name == "simon" && !builtins.pathExists "/etc/hp-os/standard-device"
        then self.homeConfigurations.simon-daytona
        else standardHome name;
      packages.aarch64-linux.hp-os-account-setup = pkgs.writeShellScriptBin "hp-os-account-setup" ''
        export HP_OS_PROFILE_FLAKE=${self.outPath}
        # Keep locked flake inputs available for a first login after garbage collection.
        : ${builtins.concatStringsSep " " (map (item: item.src.outPath) (builtins.genericClosure {
          startSet = [ { key = self.outPath; src = self; } ];
          operator = item: map (src: { key = src.outPath; inherit src; }) (builtins.attrValues (item.src.inputs or {}));
        }))}
        exec /bin/bash ${./goran/installer/account-setup.sh} "$@"
      '';
      homeModules.fleetApps = import ./fleet/home.nix;
      homeManagerModules.default = import ./fleet/home.nix;
      packages.x86_64-linux.upscayl = let p = import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; in p.callPackage ./goran/desktop/upscayl/package.nix {};
      packages.aarch64-linux.upscayl = pkgs.callPackage ./goran/desktop/upscayl/package.nix {};
      # The HP-OS login screen; installed with goran/installer/system/hp-os-login-theme.sh.
      packages.aarch64-linux.hp-os-login-theme = import ./goran/desktop/hp-snap/login-theme.nix {
        inherit pkgs;
        hposFonts = pkgs.callPackage (hp-os + "/packaging/fonts") { };
        wallpapers = import ./goran/desktop/hp-snap/wallpapers.nix { inherit pkgs; };
      };
      # The login screen's Add user setup; installed with goran/installer/system/hp-os-add-user.sh.
      packages.aarch64-linux.hp-os-add-user = import ./goran/desktop/hp-snap/add-user.nix {
        inherit pkgs;
        quickshell = hp-os.inputs.nixpkgs.legacyPackages.${system}.quickshell;
      };
      # The USB stick that turns a laptop into an HP-OS laptop; made with goran/installer/usb/make-usb.sh.
      packages.aarch64-linux.hp-os-usb-installer = import ./goran/installer/usb/usb-installer.nix {
        inherit pkgs;
        hposFonts = pkgs.callPackage (hp-os + "/packaging/fonts") { };
        wallpapers = import ./goran/desktop/hp-snap/wallpapers.nix { inherit pkgs; };
        logo = ./goran/desktop/hp-snap/login-theme/hp-logo.png;
      };
      packages.aarch64-linux.foundation-sunshine = import ./goran/remote-access/pkgs/foundation-sunshine.nix { inherit pkgs; };
      homeConfigurations.simon-daytona = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit hp-os dank-material-shell dms-plugin-registry xwayland-satellite;
          n1xPersonalServices = false;
        };
        modules = [
          ./fleet/home.nix
          ./goran/installer/simon-home.nix
          ./goran/remote-access/simon.nix
          ./goran/installer/simon-apps.nix
          ./goran/installer/simon-update.nix
          ./goran/desktop/microsoft365-webapps.nix
          ./goran/installer/simon-local.nix
          ./goran/desktop/cosmic-niri.nix
          ./goran/desktop/hp-os.nix
          ./goran/desktop/search-iq.nix
          ./goran/desktop/niri.nix
          ./goran/desktop/launchers.nix
          ./goran/desktop/dms.nix
          ./goran/desktop/power.nix
          ./goran/desktop/hp-os-theme.nix
          ./goran/desktop/apps.nix
          ./goran/headphones/home.nix
        ];
      };
    } {
      # Other people's HP-OS accounts (hp-os-users.nix): the shared desktop only.
      # Left out on purpose: Simon's personal modules, the headphone apps and Ask IQ (~1.2 GB per user).
      homeConfigurations = builtins.listToAttrs (map (name: {
        name = "hp-os-${name}";
        value = standardHome name;
      }) (import ./hp-os-users.nix));
    };
}
