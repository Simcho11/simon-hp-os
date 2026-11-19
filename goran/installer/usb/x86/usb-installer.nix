# Everything the x86 HP-OS USB stick boots into: a small, self-contained installer that lives in memory.
{ pkgs, hposFonts, wallpapers, logo }:
let
  python = pkgs.python3.withPackages (p: [ p.pillow ]);
  tools = pkgs.buildEnv {
    name = "hp-os-x86-installer-tools";
    paths = with pkgs; [ bashInteractive coreutils util-linux gptfdisk e2fsprogs dosfstools rsync efibootmgr kmod eudev gnugrep gnused findutils procps cpio python ];
    pathsToLink = [ "/bin" "/sbin" "/lib/udev" "/etc/udev" ];
    ignoreCollisions = true;
  };
  closure = pkgs.closureInfo { rootPaths = [ tools ]; };
in pkgs.runCommand "hp-os-x86-usb-installer" { nativeBuildInputs = [ pkgs.cpio pkgs.zstd python pkgs.findutils ]; } ''
  mkdir -p root/installer/assets root/nix/store "$out"
  while IFS= read -r path; do cp -a "$path" root/nix/store/; done < ${closure}/store-paths
  ln -s ${tools} root/env
  mkdir -p root/lib root/etc
  ln -s ${tools}/lib/udev root/lib/udev
  cp ${../installer.py} root/installer/installer.py
  cp ${./installer_x86.py} root/installer/installer_x86.py
  cp ${./init.sh} root/init
  chmod 755 root/init
  cp ${logo} root/installer/assets/hp-logo.png
  regular=$(find -L ${hposFonts} -iname 'HarmonyOS_Sans.ttf' -o -iname 'HarmonyOS_Sans_Regular.ttf' | head -n 1)
  bold=$(find -L ${hposFonts} -iname 'HarmonyOS_Sans_Bold.ttf' | head -n 1)
  cp "$regular" root/installer/assets/regular.ttf
  cp "''${bold:-$regular}" root/installer/assets/bold.ttf
  python3 - <<PY
  from PIL import Image, ImageFilter
  picture = Image.open("${wallpapers}/hp-os-daybreak.png").convert("RGB")
  picture.thumbnail((2880, 1800))
  picture.filter(ImageFilter.GaussianBlur(52)).save("root/installer/assets/backdrop.jpg", quality=88)
  PY
  ln -s ${tools} "$out/tools"
  (cd root && find . -print0 | LC_ALL=C sort -z | cpio --null --quiet -H newc -o --reproducible) | zstd -T0 -12 > "$out/installer.cpio.zst"
''
