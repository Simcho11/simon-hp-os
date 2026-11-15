# Use the consumer package set so Qt and runtime dependencies stay aligned.
{ pkgs, dank-material-shell }:
(dank-material-shell.lib.mkDmsShell pkgs).overrideAttrs (old: {
  patches = (old.patches or []) ++ [ ./dms-brightness/manager.patch ];
  postPatch = (old.postPatch or "") + ''
    cp ${./dms-brightness/goran_panel.go} internal/server/brightness/goran_panel.go
    cp ${./dms-brightness/goran_panel_test.go} internal/server/brightness/goran_panel_test.go
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    go test ./internal/server/brightness
    runHook postCheck
  '';
})
