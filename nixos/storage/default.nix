{ config, lib, ... }:
{
  options.nabu.storage.persistentDirectory = lib.mkOption {
    type = lib.types.strMatching "/[^[:space:]]+";
    default = "/nix/persistent";
    description = "Persistent system state directory, also used for image initialization data.";
  };

  config.boot.initrd.systemd = lib.mkIf config.boot.initrd.systemd.enable {
    # fstab's x-systemd.growfs needs these in the initrd as well as stage 2.
    additionalUpstreamUnits = [
      "systemd-growfs@.service"
      "systemd-growfs-root.service"
    ];
    storePaths = [ "${config.boot.initrd.systemd.package}/lib/systemd/systemd-growfs" ];
  };
}
