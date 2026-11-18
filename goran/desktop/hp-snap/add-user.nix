# HP-OS "Add user": the step-by-step account setup opened from the login screen.
# Installed with goran/installer/system/hp-os-add-user.sh.
{ pkgs, quickshell }:
pkgs.runCommand "hp-os-add-user" { } ''
  app="$out/share/hp-os-add-user"
  mkdir -p "$app" "$out/bin"
  cp ${./add-user/shell.qml} "$app/shell.qml"
  cp ${./add-user/accounts.py} "$app/accounts.py"
  cp ${./add-user/SetupBar.qml} "$app/SetupBar.qml"
  mkdir -p "$app/first-setup"
  cp ${./add-user/first-setup.qml} "$app/first-setup/shell.qml"
  cp ${./add-user/SetupBar.qml} "$app/first-setup/SetupBar.qml"
  cp ${./login-theme/LoginActivity.qml} "$app/LoginActivity.qml"
  cp ${./login-theme/LoginAvatar.qml} "$app/LoginAvatar.qml"
  cp ${./login-theme/LoginText.qml} "$app/LoginText.qml"
  ${pkgs.python3.withPackages (p: [ p.numpy p.pillow ])}/bin/python3 ${./add-user/pictures.py} "$app/pictures"
  cat > "$out/bin/hp-os-add-user" <<EOF
  #!/bin/sh
  export HP_OS_ADD_USER_HELPER="$app/accounts.py"
  export QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Basic
  exec ${quickshell}/bin/quickshell -n -p "$app/shell.qml"
  EOF
  sed -i 's/^  //' "$out/bin/hp-os-add-user"
  chmod +x "$out/bin/hp-os-add-user"

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
  export GBM_BACKEND=nvidia-drm __GLX_VENDOR_LIBRARY_NAME=nvidia
  exec /usr/bin/timeout --foreground 1800 /usr/bin/dbus-run-session -- $niri --config "$app/first-setup/niri.kdl"
  EOF
  sed -i 's/^  //' "$app/first-setup/screen" "$app/first-setup/niri.kdl" "$out/bin/hp-os-first-setup"
  chmod +x "$app/first-setup/screen" "$out/bin/hp-os-first-setup"
''
