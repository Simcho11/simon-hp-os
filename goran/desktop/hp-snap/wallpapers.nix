# Simon's day/night wallpaper pair, used by the desktop (home.nix) and the login screen.
# Daybreak is rendered from its source (pixel-identical to his PNG); the dark planet is his 4x
# wallpaper, stored as a 1 MB WebP and turned back into a PNG here.
{ pkgs }:
pkgs.runCommandCC "hp-os-day-night-wallpapers" {
  nativeBuildInputs = [ pkgs.netpbm pkgs.libwebp ];
} ''
  $CC -O2 -fopenmp -o daybreak ${./wallpaper/daybreak.c} -lm
  ./daybreak 5760 3600 > daybreak.ppm
  mkdir -p "$out"
  pnmtopng -compression 9 daybreak.ppm > "$out/hp-os-daybreak.png"
  dwebp -quiet ${./wallpaper/harmony-night.webp} -o "$out/hp-os-harmony-night.png"
''
