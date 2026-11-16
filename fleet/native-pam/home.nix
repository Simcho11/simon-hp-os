{ config, lib, pkgs, ... }:
let
  cfg = config.programs.hp-os-fleet.nativePam;
  guard = pkgs.writeShellScriptBin "desktop-native-pam-check" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.patchelf pkgs.coreutils ]}:$PATH"
    checked=0
    for command in hp-os dms; do
      launcher="$1/bin/$command"
      if [ -e "$launcher" ]; then
        checked=$((checked + 1))
        root=$(dirname "$(dirname "$(readlink -f "$launcher")")")
        if [ "$command" = dms ]; then
          ${pkgs.python3}/bin/python3 ${./.}/check.py "$root" qs
        else
          ${pkgs.python3}/bin/python3 ${./.}/check.py "$root"
        fi
      fi
    done
    [ "$checked" -gt 0 ] || { echo "No candidate desktop shells found" >&2; exit 1; }
  '';
in {
  options.programs.hp-os-fleet.nativePam.enable = lib.mkEnableOption "Ubuntu native PAM activation gate for HP-OS and Dux";
  config = lib.mkIf cfg.enable {
    assertions = [{ assertion = pkgs.stdenv.hostPlatform.isAarch64; message = "Native PAM bridge currently supports Ubuntu ARM64."; }];
    home.packages = [ guard ];
    # Every activation path, including direct activation and Home Manager switch,
    # validates the candidate before replacing profile files or restarting shells.
    home.activation.verifyDesktopNativePam = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      run ${guard}/bin/desktop-native-pam-check ${config.home.path}
    '';
  };
}
