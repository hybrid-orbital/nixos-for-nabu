{ config, lib, ... }:
{
  imports = [
    ./esp.nix
    ./rootfs.nix
    ./registration.nix
  ];

  options.nabu.image = {
    fsType = lib.mkOption {
      type = lib.types.enum [
        "ext4"
        "btrfs"
      ];
      description = "Filesystem of the image flashed into the existing linux partition.";
    };
    mountPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Runtime mount points mapped to image-relative paths; Btrfs paths become subvolumes.";
    };
    registrationPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.nabu.storage.persistentDirectory}/nix-path-registration";
      defaultText = lib.literalExpression ''"''${config.nabu.storage.persistentDirectory}/nix-path-registration"'';
      description = "Runtime path to the initial Nix store registration manifest on persistent storage.";
    };
    rootFsExtraSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      description = "Extra free space in MiB beyond the staged filesystem contents.";
    };
    compress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Compress the rootfs image with zstd.";
    };
  };
}
