{ config, lib, ... }: {
  config = lib.mkIf (config.programs.goran-hp-os.enable && config.programs.hp-os-fleet.enable && config.programs.hp-os-fleet.wallpapers.enable) {
    home.file."Pictures/Wallpapers/HP-OS" = {
      source = ./images;
      recursive = true;
    };
  };
}
