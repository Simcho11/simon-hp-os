{ config, lib, pkgs, hp-os, ... }:
let
  cfg = config.programs.goran-hp-os;
  # The ARM OmniBook's NVIDIA N1X needs its own graphics settings; x86 laptops use the standard drivers.
  isN1x = pkgs.stdenv.hostPlatform.isAarch64;
  ubuntuLibDir = if isN1x then "aarch64-linux-gnu" else "x86_64-linux-gnu";
  nativePamBridge = if isN1x then ./native-pam-bridge.py else pkgs.runCommand "native-pam-bridge.py" { } ''
    sed 's#/usr/lib/aarch64-linux-gnu#/usr/lib/${ubuntuLibDir}#' ${./native-pam-bridge.py} > "$out"
  '';
  hpPkgs =hp-os.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  # Files runs with its own settings folder and Qt theme (hp-os-files). This KIO
  # starts the applications Files opens with the environment Files was started
  # from, so they keep the user's own settings and sign-ins, and pastes files into
  # the folder they are already in as Windows and macOS do (a Cut stays put, a Copy
  # is numbered beside them). Only Files loads it.
  filesKio = hpPkgs.kdePackages.kio.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./hp-snap/files-launch-env.patch ./hp-snap/files-paste-in-place.patch ];
  });
  # Files with a glass slot showing where a dropped item will land.
  filesWithDropSlot = hpPkgs.kdePackages.dolphin.overrideAttrs (old: {
    # files-new-window: "Open in New Window", "Show in folder" and a detached tab
    # start HP-OS Files (hp-os-files) rather than a bare "dolphin" off PATH.
    patches = (old.patches or [ ]) ++ [ ./hp-snap/files-drop-slot.patch ./hp-snap/files-new-window.patch ];
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ hpPkgs.patchelf ];
    # Load the KIO above. Its libraries are the same build with one change, so
    # every library Files loads shares the copy the program itself loads first.
    postFixup = (old.postFixup or "") + ''
      patched=0
      for elf in "$out"/bin/.dolphin-wrapped "$out"/bin/dolphin "$out"/lib/libdolphinprivate.so.*; do
        [ -f "$elf" ] && [ ! -L "$elf" ] || continue
        patchelf --print-needed "$elf" 2>/dev/null | grep -qx 'libKF6KIOGui.so.6' || continue
        patchelf --set-rpath "${filesKio}/lib:$(patchelf --print-rpath "$elf")" "$elf"
        patched=$((patched + 1))
      done
      [ "$patched" -ge 2 ] || { echo "Files: expected to point Dolphin at the HP-OS KIO" >&2; exit 1; }
    '';
  });
  originalQs = hpPkgs.quickshell;
  originalShell = hp-os.packages.${pkgs.stdenv.hostPlatform.system}.default;
  globalTouchNiri = originalShell.niri.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./niri-long-press.patch ];
  });
  # hp-snap (./hp-snap): patched niri, xwayland-satellite and shell, when hpSnap.enable is set.
  useSnap = cfg.hpSnap.enable;
  snap = import ./hp-snap { inherit pkgs lib; baseNiri = globalTouchNiri; baseRuntime = originalShell.shell; };
  sessionNiri = if useSnap then snap.niri else globalTouchNiri;
  globalTouchSupport = originalShell.touchSupport.override { niri = sessionNiri; };
  # Only this Quickshell uses Ubuntu PAM. Its Qt and children retain Nix libraries.
  nativeQs = pkgs.runCommand originalQs.name {
    nativeBuildInputs = [ pkgs.patchelf pkgs.python3 ];
  } ''
    cp -a ${originalQs} "$out"
    chmod -R u+w "$out"
    python3 - "$out" '${originalQs}' <<'PYWRAP'
import pathlib, sys
new, old = map(str.encode, sys.argv[1:])
assert len(new) == len(old), "binary wrapper prefix length changed"
for name in ("qs", "quickshell"):
    path = pathlib.Path(sys.argv[1], "bin", name)
    data = path.read_bytes()
    assert old in data, "expected binary wrapper reference missing"
    path.write_bytes(data.replace(old, new))
PYWRAP
    binary="$out/bin/.quickshell-wrapped"
    rpath=$(patchelf --print-rpath "$binary")
    patchelf --replace-needed libpam.so.0 /usr/lib/${ubuntuLibDir}/libpam.so.0 \
      --force-rpath --set-rpath "$rpath:${lib.getLib hpPkgs.pcre2}/lib:${config.home.homeDirectory}/.local/state/hp-os/native-pam/current" "$binary"
  '';
  nativePamRun = pkgs.writeShellScript "hp-os-native-pam-run" ''
    bridge="$HOME/.local/state/hp-os/native-pam/current"
    if [[ ! -r "$bridge/libpam.so.0" ]]; then
      echo "HP-OS native PAM bridge is missing; run Home Manager activation." >&2
      exit 1
    fi
    exec ${nativeQs}/bin/qs "$@"
  '';
  nativeShell = originalShell.overrideAttrs (old: {
    passthru = old.passthru // { niri = sessionNiri; touchSupport = globalTouchSupport; };
    postFixup = (old.postFixup or "") + ''
      ${pkgs.python3}/bin/python3 ${./hp-os-battery.py} "$out/share/hp-os/packaging/default-config.json"
      for touchTool in touch-support hp-os-keyboard; do
        ln -sfn ${globalTouchSupport}/bin/$touchTool "$out/bin/$touchTool"
      done
      substituteInPlace "$out/bin/hp-os" \
        --replace-fail '${originalShell.touchSupport}' '${globalTouchSupport}'
      substituteInPlace "$out/bin/hp-os" "$out/bin/hp-os-toggle-floating-all" \
        --replace-fail '${originalShell.niri}' '${sessionNiri}'
      substituteInPlace "$out/bin/.hp-os-wrapped" \
        --replace-fail 'exec qs -n -p "$runtime" "$@"' \
        'exec ${nativePamRun} -n -p "$runtime" "$@"'
    '' + lib.optionalString useSnap ''
      substituteInPlace "$out/bin/.hp-os-wrapped" \
        --replace-fail '${originalShell.shell}' '${snap.runtime}'
      ${pkgs.python3}/bin/python3 ${./hp-snap/launcher.py} \
        "$out/bin/.hp-os-wrapped" "$out/bin/hp-os" ${snap.xwaylandSatellite}
      ${pkgs.bash}/bin/bash ${./hp-snap/fix-icons.sh} \
        "$out/share/hp-os/packaging/files/data/icons" ${./hp-snap/icons/trash.svg} ${./hp-snap/icons/trash-full.svg}
      ${pkgs.python3}/bin/python3 ${./hp-snap/apply-defaults.py} \
        ${./hp-snap/defaults.json} "$out/share/hp-os/packaging/default-config.json"
      ${pkgs.python3}/bin/python3 ${./hp-snap/apply-defaults.py} \
        ${./hp-snap/glass-and-tray.json} "$out/share/hp-os/packaging/default-config.json"
      ${pkgs.python3}/bin/python3 ${./hp-snap/apply-defaults.py} \
        ${./hp-snap/window-space.json} "$out/share/hp-os/packaging/default-config.json"
      ${pkgs.python3}/bin/python3 ${./hp-snap/apply-defaults.py} \
        ${./hp-snap/hp-blue-accent.json} "$out/share/hp-os/packaging/default-config.json"
      ${pkgs.python3}/bin/python3 ${./hp-snap/glass-niri.py} "$out/share/hp-os/packaging/niri.kdl"
      ${pkgs.python3}/bin/python3 ${./hp-snap/window-style.py} "$out/share/hp-os/packaging/niri.kdl"
      mkdir -p "$out/share/hp-os/arrival"
      cp ${./hp-snap/DesktopArrival.qml} "$out/share/hp-os/arrival/DesktopArrival.qml"
      cp ${./hp-snap/login-theme/LoginActivity.qml} "$out/share/hp-os/arrival/LoginActivity.qml"
      substituteInPlace "$out/bin/.hp-os-wrapped" \
        --replace-fail '  run)' '  run)
    if [[ "''${HP_OS_AUTHENTICATED_LOGIN:-0}" == 1 && "''${HP_OS_OWNED_SESSION:-0}" == 1 && -n "''${NIRI_SOCKET:-}" ]] && mkdir -m 700 -- "$NIRI_SOCKET.arrival" 2>/dev/null; then
      qs -n -p "'"$out"'/share/hp-os/arrival/DesktopArrival.qml" &
    fi'
      substituteInPlace "$out/bin/.hp-os-wrapped" \
        --replace-fail 'export INIR_RUNTIME_DIR="$runtime"' 'export INIR_RUNTIME_DIR="$runtime" HP_OS_RUNTIME="$runtime"
export QT_WAYLAND_DECORATION="''${QT_WAYLAND_DECORATION:-adwaita}"'
      # SDDM can create config.json before the shell starts. Apply each migration
      # after first-login seeding and before Quickshell reads that configuration.
      substituteInPlace "$out/bin/.hp-os-wrapped" \
        --replace-fail '    python3 "$packaging/write-version.py" "$config"' \
        '    ${lib.optionalString cfg.hpSnap.manageHouseDefaults "python3 ${./hp-snap/apply-defaults.py} ${./hp-snap/defaults.json} \"$config/config.json\" \"$INIR_STATE_DIR/hp-snap-defaults-v4\""}
    ${pkgs.python3}/bin/python3 ${./hp-snap/apply-defaults.py} ${./hp-snap/glass-and-tray.json} "$config/config.json" "$INIR_STATE_DIR/hp-snap-glass-tray-v2"
    ${pkgs.python3}/bin/python3 ${./hp-snap/apply-defaults.py} ${./hp-snap/window-space.json} "$config/config.json" "$INIR_STATE_DIR/hp-snap-window-space-v1"
    python3 "$packaging/write-version.py" "$config"'
      substituteInPlace "$out/bin/hp-os-files" \
        --replace-fail 'env["QT_PLUGIN_PATH"] = "' 'env["QT_PLUGIN_PATH"] = "${hpPkgs.qt6.qtwayland}/${hpPkgs.qt6.qtbase.qtPluginPrefix}:'
      # Files shows a glass slot where a dropped item will land.
      substituteInPlace "$out/bin/hp-os-files" \
        --replace-fail '${hpPkgs.kdePackages.dolphin}/bin/dolphin' '${filesWithDropSlot}/bin/dolphin'
      # Files drags like macOS: no menu on drop, and folders spring open under a held file.
      substituteInPlace "$out/bin/hp-os-files" \
        --replace-fail 'def prepare_environment(environ, assets):' "$(cat ${./hp-snap/files-drag.py})"$'\n\n\ndef prepare_environment(environ, assets):' \
        --replace-fail '    apply_files_palette(profile / "kdeglobals", assets, mode)' $'    apply_files_palette(profile / "kdeglobals", assets, mode)\n    keep_mac_file_drags(profile)'
      # Seed a new desktop on the desktop grid (it starts at 0; 104 px pitch with the 8 px grid).
      substituteInPlace "$out/share/hp-os/packaging/initialize-config.py" \
        --replace-fail 'x=24 + (index // 6) * 104, y=24 + (index % 6) * 104' \
        'x=(index // 6) * 104, y=(index % 6) * 104'
    '' + ''
      mkdir -p "$out/share/hp-os/native-pam"
      ln -s ${nativeQs}/bin/qs "$out/share/hp-os/native-pam/qs"
      ln -s ${lib.getLib hpPkgs.pcre2}/lib/libpcre2-8.so.0 "$out/share/hp-os/native-pam/pcre"
    '';
  });
  shell = config.programs.hp-os.package;
  touch = config.programs.hp-os.touchSupport;
  keyboardEnabled = touch.enable && touch.keyboard.mode != "off" && touch.keyboard.backend != "none";
  fonts = pkgs.callPackage (hp-os + "/packaging/fonts") { };
  keyboardConfig = pkgs.writeText "goran-keyboard.kdl" ''
    input { keyboard { xkb { options "ctrl:nocaps"; }; }; }
  '';
  installKeyboard = "${pkgs.python3}/bin/python3 ${./hp-os-keyboard-config.py} ${keyboardConfig}";
  launcher = pkgs.writeShellScriptBin "hp-os-session" ''
    export PATH="$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
    ${lib.optionalString isN1x "export GBM_BACKEND=nvidia-drm\nexport __GLX_VENDOR_LIBRARY_NAME=nvidia\n"}if [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
      echo 'Start HP-OS from a login manager or a free TTY.' >&2
      exit 1
    fi
    ${if keyboardEnabled then ''
      # Native Wayland text-input reaches the one HP-OS/Squeekboard seat owner.
      unset GTK_IM_MODULE QT_IM_MODULE XMODIFIERS
    '' else ''
      # The private HP-OS bus gets its own Fcitx instance below. The existing
      # DMS instance stays on its own compositor and session bus.
      export GTK_IM_MODULE=fcitx
      export QT_IM_MODULE=fcitx
      export XMODIFIERS=@im=fcitx
    ''}
    ${pkgs.python3}/bin/python3 - <<'PY'
    import os, pathlib, tempfile
    root = pathlib.Path(os.environ.get('INIR_NIRI_CONFIG_DIR', os.environ.get('INIR_CONFIG_DIR', os.environ.get('XDG_CONFIG_HOME', str(pathlib.Path.home()/'.config'))+'/hp-os')+'/niri'))
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    (root/'config.d').mkdir(exist_ok=True, mode=0o700)
    def write(path, text):
        fd, temporary = tempfile.mkstemp(prefix='.'+path.name, dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as stream: stream.write(text)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    main = root/'config.kdl'
    text = main.read_text() if main.exists() else pathlib.Path('${shell}/share/hp-os/packaging/niri.kdl').read_text()
    ${lib.optionalString useSnap (builtins.readFile ./hp-snap/login-backdrop.py)}
    include = 'include "config.d/61-goran-ime.kdl"'
    write(root/'config.d/61-goran-ime.kdl', ${builtins.toJSON (if keyboardEnabled then "// HP-OS controller owns this session's input-method seat.\n" else "// Private HP-OS bus only; never replace another session's IME.\nspawn-at-startup \"${pkgs.fcitx5}/bin/fcitx5\" \"-D\"\n")})
    with (root/'config.d/61-goran-ime.kdl').open('a') as stream:
        stream.write('input { touch { map-to-output "eDP-1"; }; }\n')
    if include not in (line.strip() for line in text.splitlines()):
        write(main, text.rstrip()+'\n'+include+'\n')
    PY
    ${installKeyboard}
    exec ${shell}/bin/hp-os session "$@"
  '';
in {
  imports = [ ./upscayl/home.nix ./wallpapers/home.nix hp-os.homeManagerModules.default ./hp-os-appearance-schedule.nix ./hp-snap/home.nix ./hp-os-default-apps.nix ];
  options.programs.goran-hp-os.enable = lib.mkEnableOption "the additional HP-OS login session";
  options.programs.goran-hp-os.hpSnap.enable = lib.mkEnableOption
    "hp-snap's patched niri, xwayland-satellite and shell (goran/desktop/hp-snap)" // { default = true; };
  options.programs.goran-hp-os.hpSnap.manageHouseDefaults = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install the starter dock, wallpaper, icon layout and Niri rules into existing homes.";
  };
  config = lib.mkIf cfg.enable {
    programs.hp-os = {
      enable = true;
      package = nativeShell;
      touchSupport = {
        enable = lib.mkDefault true;
        profile = lib.mkDefault "laptop";
        gestures.enable = lib.mkDefault true;
        # Goran is a laptop: never start or expose an on-screen keyboard.
        keyboard.mode = lib.mkForce "off";
        keyboard.showPanelButton = lib.mkForce false;
        gestures.keyboardEdge = lib.mkForce false;
        keyboard.backend = lib.mkDefault "hp-os-qml";
        keyboard.fallback = lib.mkDefault "squeekboard";
        rotation.mode = lib.mkDefault "off";
      };
    };
    home.activation.hpOsKeyboard = lib.hm.dag.entryAfter [ "hposNiriBindings" ] ''
      run ${installKeyboard}
    '';
    home.activation.hpOsNativePam = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.python3}/bin/python3 ${nativePamBridge} \
        "$HOME/.local/state/hp-os/native-pam/current" \
        ${lib.getLib hpPkgs.pcre2}/lib/libpcre2-8.so.0
    '';
    home.activation.hpOsDesktopControls = lib.hm.dag.entryAfter [ "linkGeneration" "hposNiriBindings" ] ''
      run ${pkgs.python3}/bin/python3 ${./hp-os-battery.py} "$HOME/.config/hp-os/config.json"
      run ${pkgs.python3}/bin/python3 ${./files-dock-pin.py} "$HOME/.config/hp-os/config.json"
    '';
    home.packages = [ fonts launcher ];
    # Keep launcher discovery current during a preserved session whose
    # XDG_DATA_DIRS still includes the previous HP-OS store generation.
    xdg.dataFile."applications/org.kde.dolphin.desktop".source =
      "${shell}/share/hp-os/applications/org.kde.dolphin.desktop";
    # Files is the one file manager: folders, the Dock's Trash, and "Show in
    # folder" from other apps (org.freedesktop.FileManager1, which otherwise
    # starts the system's Nautilus or an unthemed Dolphin) all open in it.
    xdg.mimeApps.defaultApplications."inode/directory" = [ "org.kde.dolphin.desktop" ];
    xdg.dataFile."applications/hp-os-trash.desktop".source =
      "${shell}/share/applications/hp-os-trash.desktop";
    xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text = ''
      [D-BUS Service]
      Name=org.freedesktop.FileManager1
      Exec=${shell}/bin/hp-os-files --daemon
    '';
    # An unmanaged Trash launcher from an earlier build pointed at a Files without
    # today's changes. Keep it, set aside, so the managed one above can replace it.
    home.activation.hpOsFilesStaleTrash = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      run ${pkgs.python3}/bin/python3 ${./hp-snap/files-stale-launchers.py} \
        "${config.xdg.dataHome}/applications" "${config.xdg.stateHome}/hp-os/files-migration"
    '';
    # Files: right-click a picture > Set as Wallpaper.
    xdg.dataFile."kio/servicemenus/hp-os-set-wallpaper.desktop" = lib.mkIf useSnap {
      executable = true;
      text = ''
        [Desktop Entry]
        Type=Service
        MimeType=image/png;image/jpeg;image/webp;image/gif;image/bmp;image/avif;image/heif;image/jxl;
        Actions=setWallpaper;
        X-KDE-Priority=TopLevel

        [Desktop Action setWallpaper]
        Name=Set as Wallpaper
        Icon=preferences-desktop-wallpaper
        Exec=${pkgs.python3}/bin/python3 -I ${snap.runtime}/share/quickshell/inir/scripts/hp-snap/set_wallpaper.py ${nativeQs}/bin/qs %f
      '';
    };
    fonts.fontconfig.enable = true;
    xdg.configFile."xdg-desktop-portal/hp-os-portals.conf".text = ''
      [preferred]
      default=gnome;gtk
      org.freedesktop.impl.portal.Access=gtk
      org.freedesktop.impl.portal.Notification=gtk${lib.optionalString useSnap "\norg.freedesktop.impl.portal.Settings=gtk"}
      org.freedesktop.impl.portal.FileChooser=gtk
      org.freedesktop.impl.portal.Secret=gnome-keyring
    '';
  };
}
