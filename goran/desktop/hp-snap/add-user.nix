# HP-OS "Add user": the step-by-step account setup opened from the login screen.
# Installed with goran/installer/system/hp-os-add-user.sh.
{ pkgs, quickshell }:
pkgs.runCommand "hp-os-add-user" { } ''
  app="$out/share/hp-os-add-user"
  mkdir -p "$app" "$out/bin"
  cp ${./add-user/shell.qml} "$app/shell.qml"
  cp ${./add-user/accounts.py} "$app/accounts.py"
  cp ${./add-user/SetupBar.qml} "$app/SetupBar.qml"
  cp ${./add-user/device-client.py} "$app/device-client.py"
  mkdir -p "$app/factory-reset"
  cp ${./add-user/factory-reset.qml} "$app/factory-reset/shell.qml"
  cp ${./add-user/device-client.py} "$app/factory-reset/device-client.py"
  cp ${./login-theme/LoginActivity.qml} "$app/factory-reset/LoginActivity.qml"
  mkdir -p "$app/software-update"
  cp ${./add-user/software-update.qml} "$app/software-update/shell.qml"
  cp ${./add-user/device-client.py} "$app/software-update/device-client.py"
  mkdir -p "$app/first-setup"
  cp ${./add-user/first-setup.qml} "$app/first-setup/shell.qml"
  cp ${./add-user/SetupBar.qml} "$app/first-setup/SetupBar.qml"
  cp ${./login-theme/LoginActivity.qml} "$app/LoginActivity.qml"
  cp ${./login-theme/LoginAvatar.qml} "$app/LoginAvatar.qml"
  cp ${./login-theme/LoginText.qml} "$app/LoginText.qml"
  cp ${./login-theme/GlassShape.qml} "$app/GlassShape.qml"
  cp ${./login-theme/LiquidLens.qsb} "$app/LiquidLens.qsb"
  ${pkgs.python3.withPackages (p: [ p.numpy p.pillow ])}/bin/python3 ${./add-user/pictures.py} "$app/pictures"
  cat > "$out/bin/hp-os-add-user" <<EOF
  #!/bin/sh
  export HP_OS_ADD_USER_HELPER="$app/accounts.py"
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic HP_OS_QRENCODE=${pkgs.qrencode}/bin/qrencode
  # A Wi-Fi sign-in page during first-time setup opens in the same Chrome every account has.
  export HP_OS_CHROME=${pkgs.google-chrome}/bin/google-chrome-stable
  case "\$1" in
    hpos-add-user:first-boot) export HP_OS_FIRST_BOOT=1 ;;
    # The login screen's "Forgot your password?": a new password with the recovery key, for that login only.
    hpos-add-user:recover:*)
      who="\''${1#hpos-add-user:recover:}"
      case "\$who" in ""|-*|*[!a-z0-9_-]*) exit 1 ;; esac
      export HP_OS_RECOVERY="reset:\$who" ;;
  esac
  exec ${quickshell}/bin/quickshell -n -p "$app/shell.qml"
  EOF
  sed -i 's/^  //' "$out/bin/hp-os-add-user"
  chmod +x "$out/bin/hp-os-add-user"

  # Settings > General > Factory reset.
  cat > "$out/bin/hp-os-factory-reset" <<EOF
  #!/bin/sh
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic
  exec ${quickshell}/bin/quickshell -n -p "$app/factory-reset/shell.qml"
  EOF
  sed -i 's/^  //' "$out/bin/hp-os-factory-reset"
  chmod +x "$out/bin/hp-os-factory-reset"

  # Settings > Users & Accounts > Recovery key: an administrator makes a new one.
  cat > "$out/bin/hp-os-recovery-key" <<EOF
  #!/bin/sh
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic HP_OS_RECOVERY=new HP_OS_QRENCODE=${pkgs.qrencode}/bin/qrencode
  exec ${quickshell}/bin/quickshell -n -p "$app/shell.qml"
  EOF
  sed -i 's/^  //' "$out/bin/hp-os-recovery-key"
  chmod +x "$out/bin/hp-os-recovery-key"

  # The welcome on a person's desktop at their first sign-in (scripts/welcome-user.sh), and from Settings › Welcome.
  mkdir -p "$app/welcome"
  cp ${./add-user/welcome.qml} "$app/welcome/shell.qml"
  cp ${./login-theme/GlassShape.qml} "$app/welcome/GlassShape.qml"
  cp ${./login-theme/LiquidLens.qsb} "$app/welcome/LiquidLens.qsb"
  cat > "$out/bin/hp-os-welcome" <<EOF
  #!/bin/sh
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic
  exec ${quickshell}/bin/quickshell -n -p "$app/welcome/shell.qml"
  EOF
  sed -i 's/^  //' "$out/bin/hp-os-welcome"
  chmod +x "$out/bin/hp-os-welcome"

  # Settings > General > Software Update.
  cat > "$out/bin/hp-os-software-update" <<EOF
  #!/bin/sh
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic
  exec ${quickshell}/bin/quickshell -n -p "$app/software-update/shell.qml"
  EOF
  sed -i 's/^  //' "$out/bin/hp-os-software-update"
  chmod +x "$out/bin/hp-os-software-update"

  # First sign-in of an account that isn't set up yet: HP logo and a progress bar on black.
  niri=/opt/hp-os/niri-patch/result-hpos/bin/niri
  cat > "$app/first-setup/screen" <<EOF
  #!/bin/sh
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic HP_OS_SETUP_PROGRESS=1
  ${quickshell}/bin/quickshell -n -p "$app/first-setup/shell.qml"
  # However the screen ended, never leave this temporary display running.
  exec $niri msg action quit --skip-confirmation
  EOF
  cat > "$app/first-setup/niri.kdl" <<EOF
  hotkey-overlay { skip-at-startup; }
  prefer-no-csd
  animations { off; }
  cursor { hide-after-inactive-ms 1; }
  layout {
      background-color "#000000"
      focus-ring { off; }
      border { off; }
      shadow { off; }
  }
  window-rule { open-fullscreen true; }
  spawn-at-startup "$app/first-setup/screen"
  EOF
  cat > "$out/bin/hp-os-first-setup" <<EOF
  #!/bin/sh
  ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 "export GBM_BACKEND=nvidia-drm __GLX_VENDOR_LIBRARY_NAME=nvidia\n"}exec /usr/bin/timeout --foreground 1800 /usr/bin/dbus-run-session -- $niri --config "$app/first-setup/niri.kdl"
  EOF
  sed -i 's/^  //' "$app/first-setup/screen" "$app/first-setup/niri.kdl" "$out/bin/hp-os-first-setup"
  chmod +x "$app/first-setup/screen" "$out/bin/hp-os-first-setup"
''
