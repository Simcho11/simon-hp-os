# Patch the PAM consumer ELF, including Dux 2's embedded Qt library.
{ pkgs, package, homeDirectory, binary, command ? null, directory ? "bin", pcre ? pkgs.pcre2 }:
pkgs.runCommand package.name {
  nativeBuildInputs = [ pkgs.patchelf pkgs.python3 ];
  passthru = { inherit package; nativePam = true; };
} ''
  cp -a ${package} "$out"
  chmod -R u+w "$out"
  python3 - "$out" '${package}' <<'PY'
import pathlib, sys
new, old = map(str.encode, sys.argv[1:])
assert len(new) == len(old), "wrapper prefix length changed"
for path in pathlib.Path(sys.argv[1], "bin").glob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    data = path.read_bytes()
    # Nix makeBinaryWrapper produces ELF wrappers for qs/quickshell.
    # Their embedded paths must point to the patched copy as well.
    if path.name != "${binary}":
        path.write_bytes(data.replace(old, new))
PY
  binary="$out/${directory}/${binary}"
  patchelf --print-needed "$binary" | grep -Fx libpam.so.0
  rpath=$(patchelf --print-rpath "$binary")
  patchelf --replace-needed libpam.so.0 /usr/lib/aarch64-linux-gnu/libpam.so.0 \
    --force-rpath --set-rpath "$rpath:${pkgs.lib.getLib pcre}/lib:${homeDirectory}/.local/state/hp-os/native-pam/current" "$binary"
  patchelf --print-needed "$binary" | grep -Fx /usr/lib/aarch64-linux-gnu/libpam.so.0
  mkdir -p "$out/share/hp-os-native-pam"
  ${pkgs.lib.optionalString (command != null) ''ln -s "$out/bin/${command}" "$out/share/hp-os-native-pam/runner"''}
  ln -s "$binary" "$out/share/hp-os-native-pam/binary"
  ln -s ${pkgs.lib.getLib pcre}/lib/libpcre2-8.so.0 "$out/share/hp-os-native-pam/pcre"
''
