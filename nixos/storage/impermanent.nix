{ config, lib, ... }:
let
  persistentDirectory = config.nabu.storage.persistentDirectory;
  device = "/dev/disk/by-partlabel/linux";
  subvolumes = {
    "/nix" = "@nix";
    "${persistentDirectory}" = "@persistent";
    "/home" = "@home";
  };
  subvolume = mountPoint: name: {
    inherit device;
    fsType = "btrfs";
    neededForBoot = true;
    options = [
      "subvol=${name}"
      "compress=zstd"
      "noatime"
    ]
    ++ lib.optional (mountPoint == "/nix") "x-systemd.growfs";
  };
in
{
  # Grow the shared Btrfs filesystem once, through the /nix mount.
  fileSystems = lib.mapAttrs subvolume subvolumes // {
    "/" = {
      device = "none";
      fsType = "tmpfs";
      options = [
        "size=25%"
        "mode=755"
      ];
    };
  };

  # NixOS adds btrfs and its dependencies to the initrd from these mounts.
  boot.initrd.supportedFilesystems = [ "btrfs" ];

  # Recreate accounts declaratively on the tmpfs root. For a private password,
  # configure hashedPasswordFile on persistent storage (see docs/storage.md).
  users.mutableUsers = false;
  users.users.nabu = {
    initialPassword = null;
    password = lib.mkDefault (
      if
        config.users.users.nabu.hashedPasswordFile != null || config.users.users.nabu.hashedPassword != null
      then
        null
      else
        "nabu"
    );
  };

  # Large on-device rebuilds must not fill the tmpfs root with build trees.
  nix.settings.build-dir = "/nix/var/nix/builds";
  systemd.tmpfiles.rules = [ "d ${config.nix.settings.build-dir} 0755 root root -" ];

  environment.persistence.${persistentDirectory} = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos"
      "/var/lib/NetworkManager"
      {
        directory = "/var/lib/iwd";
        mode = "0700";
      }
      {
        directory = "/var/lib/bluetooth";
        mode = "0700";
      }
      "/var/lib/systemd"
      "/var/log"
      {
        directory = "/etc/NetworkManager/system-connections";
        mode = "0700";
      }
      {
        directory = "/root";
        mode = "0700";
      }
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };

  nabu.image = {
    fsType = "btrfs";
    mountPaths = subvolumes;
  };

  assertions = [
    {
      assertion =
        lib.all (path: !(persistentDirectory == path || lib.hasPrefix "${path}/" persistentDirectory)) [
          "/nix/store"
          "/nix/var"
          "/home"
          "/etc"
          "/var"
          "/root"
          "/boot"
          "/run"
          "/dev"
          "/proc"
          "/sys"
        ]
        && persistentDirectory != "/nix";
      message = "nabu.storage.persistentDirectory must be a separate mount, outside persisted state and system paths (for example /nix/persistent or /persist).";
    }
  ];
}
