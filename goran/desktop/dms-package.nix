# Use the consumer package set so Qt and runtime dependencies stay aligned.
{ pkgs, dank-material-shell, nativePam ? false, homeDirectory ? "/home/jonathan" }:
let
  nativeBase = import ../../fleet/native-pam/package.nix {
    inherit pkgs homeDirectory;
    package = (dank-material-shell.lib.buildDmsPkgs pkgs).dux-qt-base;
    directory = "lib";
    binary = "libdux-qt-base.so.0";
  };
  base = dank-material-shell.lib.mkDmsShell pkgs;
  dms = (if nativePam then base.override { duxQtBase = nativeBase; } else base).overrideAttrs (old: {
  patches = (old.patches or []) ++ [ ./dms-brightness/manager.patch ];
  postPatch = (old.postPatch or "") + ''
    cp ${./dms-brightness/goran_panel.go} internal/server/brightness/goran_panel.go
    cp ${./dms-brightness/goran_panel_test.go} internal/server/brightness/goran_panel_test.go
  '';
  postFixup = (old.postFixup or "") + pkgs.lib.optionalString nativePam ''
    mkdir -p "$out/share/native-pam"
    ln -s ${nativeBase}/share/native-pam/binary "$out/share/native-pam/binary"
    ln -s ${nativeBase}/share/native-pam/pcre "$out/share/native-pam/pcre"
    ln -s "$out/bin/dms" "$out/share/native-pam/runner"
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    go test ./internal/server/brightness
    runHook postCheck
  '';
});

in dms
