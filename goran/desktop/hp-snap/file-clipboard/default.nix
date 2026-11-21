# hp-os-file-clipboard: puts files on the Wayland clipboard in every form apps read
# (file list, GNOME's and KDE's cut/copy markers, plain text). See file_clipboard.py.
{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pywayland ]);
  protocols = pkgs.runCommand "hp-os-clipboard-protocols" { nativeBuildInputs = [ python pkgs.pkg-config pkgs.wayland-scanner ]; } ''
    mkdir -p "$out/hp_os_clipboard_protocols"
    python -m pywayland.scanner \
      -i ${pkgs.wayland-scanner}/share/wayland/wayland.xml \
         ${pkgs.wlr-protocols}/share/wlr-protocols/unstable/wlr-data-control-unstable-v1.xml \
      -o "$out/hp_os_clipboard_protocols"
    touch "$out/hp_os_clipboard_protocols/__init__.py"
  '';
in pkgs.writeShellScriptBin "hp-os-file-clipboard" ''
  export PYTHONPATH=${protocols}
  exec ${python}/bin/python3 -I -c 'import sys; sys.path.insert(0, "${protocols}"); sys.argv[0] = "hp-os-file-clipboard"; exec(open("${./file_clipboard.py}").read())' "$@"
''
