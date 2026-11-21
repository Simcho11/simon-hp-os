# hp-snap, built by Home Manager instead of by hand in ~/.local/share/hp-snap.
# The patch files here are copies of hp-snap's own (refresh them with ./sync-from-hp-snap.sh).
#
#   niri               HP-OS's niri + hp-snap's niri patches, on a libinput with hp-snap's patches
#   xwaylandSatellite  0.8.3 (the version HP-OS ships) + maximize/minimize/popup patches
#   runtime            HP-OS's shell runtime + hp-snap's shell changes (shell.patch)
{ pkgs, lib, baseNiri, baseRuntime }:
let
  dir = ./niri;
  niriPatches = map (name: dir + "/${name}") [
    # Order matters: the same order as hp-snap's build-hpos.nix.
    "hp-snap-niri-on-hpos.patch" "niri-dwt-delay.patch" "private-minimize-workspace.patch"
    "multi-monitor-drag.patch" "desktop-swipe.patch" "desktop-page-layers.patch"
    "desktop-swipe-smooth.patch" "desktop-rail-stacking.patch" "minimize-to-dock-icon.patch"
    "dock-keep-cursor.patch" "carry-scroll-desktops.patch" "unminimize-to-current-desktop.patch"
    "overview-workspaces.patch" "snap-overlay-keeps-windows-active.patch" "keyboard-carry.patch"
    "advertise-minimize.patch" "carry-keeps-desktop.patch" "desktop-pages.patch"
    "fullscreen-at-once.patch"
  ];
  # Puts files on the clipboard in every form apps read (desktop Copy and Cut).
  fileClipboard = import ./file-clipboard { inherit pkgs; };
in {
  niri = baseNiri.overrideAttrs (old: {
    pname = "niri-hp-snap-hpos";  # same name as hp-snap's build, so an existing build is reused
    patches = (old.patches or [ ]) ++ niriPatches;
    buildInputs = map (dep:
      if (dep.pname or "") == "libinput" then dep.overrideAttrs (libinput: {
        patches = (libinput.patches or [ ]) ++ [
          ./libinput/libinput-dwt-delay.patch
          ./libinput/libinput-newest-touch-clicks.patch
        ];
      }) else dep
    ) old.buildInputs;
  });

  xwaylandSatellite = pkgs.xwayland-satellite.overrideAttrs (old: rec {
    pname = "xwayland-satellite-hp-snap";
    version = "0.8.3";
    src = pkgs.fetchFromGitHub {
      owner = "Supreeeme";
      repo = "xwayland-satellite";
      rev = "v${version}";
      hash = "sha256-eFEjCCniMCKeWU0PcZNv+tDYe08SLFPjRplyPY8OFt4=";
    };
    cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = ./xwayland-satellite/Cargo.lock; };
    patches = (old.patches or [ ]) ++ [
      ./xwayland-satellite/hp-snap-minmax.patch
      ./xwayland-satellite/hp-snap-button-zero.patch
      ./xwayland-satellite/hp-office-popup-size.patch
    ];
  });

  # Same layout as HP-OS's runtime ($out/share/quickshell/inir), so it can stand in for it.
  runtime = pkgs.runCommand "hp-os-runtime-hp-snap" { nativeBuildInputs = [ pkgs.git ]; } ''
    mkdir -p "$out/share/quickshell"
    cp -r ${baseRuntime}/share/quickshell/inir "$out/share/quickshell/inir"
    chmod -R u+w "$out/share/quickshell/inir"
    cd "$out/share/quickshell/inir"
    git apply --binary ${./shell.patch}
    git apply ${./account-session.patch}
    git apply ${./delete-account.patch}
    git apply ${./account-profile.patch}
    git apply ${./glass-everywhere.patch}
    git apply ${./file-drops.patch}
    git apply ${./device-settings.patch}
    git apply ${./desktop-pages.patch}
    git apply ${./desktop-polish.patch}
    # One note on every display, the main display remembered by the monitor itself, displays turned off.
    git apply ${./displays.patch}
    # The desktop's files: one helper for every file operation, and no scan racing an operation.
    git apply ${./desktop-files.patch}
    # Opening an app that's already open brings its window back, a minimized one restored, instead of another copy.
    git apply ${./bring-back.patch}
    substituteInPlace scripts/hp-snap/desktop_files.py \
      --replace-fail '@fileClipboard@' ${fileClipboard}/bin/hp-os-file-clipboard
  '';
}
