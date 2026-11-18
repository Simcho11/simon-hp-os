# The HP-OS login screen (SDDM theme in ./login-theme), with HP-OS's font and the day/night
# wallpaper pair. The theme's other fonts (Inter, Rubik, Material Symbols) are already installed in
# /opt/hp-os/login/themes/hpos/fonts; goran/installer/system/hp-os-login-theme.sh copies this over them.
{ pkgs, hposFonts, wallpapers }:
pkgs.runCommand "hp-os-login-theme" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
  cp -r ${./login-theme} "$out"
  chmod -R u+w "$out"
  mkdir -p "$out/fonts"
  cp ${hposFonts}/share/fonts/truetype/hp-os/HarmonyOS_Sans.ttf "$out/fonts/"
  # Screen-sized JPEGs: the greeter decodes them at every login, a 25 MB PNG would be slow.
  magick ${wallpapers}/hp-os-daybreak.png -resize '2880x1800^' -quality 90 "$out/hp-os-daybreak.jpg"
  magick ${wallpapers}/hp-os-harmony-night.png -resize '2880x1800^' -quality 90 "$out/hp-os-harmony-night.jpg"
''
