# Boot small, real images with a generic kernel; this does not emulate nabu.
{
  pkgs,
  lib,
  impermanence,
}:
pkgs.testers.runNixOSTest {
  name = "nabu-storage-boot";
  # Allow software emulation on builders without /dev/kvm.
  requiredFeatures.kvm = false;

  nodes = lib.genAttrs [ "ext4" "impermanent" ] (
    variant:
    { config, lib, ... }:
    {
      imports = [
        ../nixos/storage
        ../nixos/images
        ../nixos/storage/${variant}.nix
      ]
      ++ lib.optional (variant == "impermanent") impermanence.nixosModules.impermanence;
      system.stateVersion = "25.11";
      boot.initrd.systemd.enable = true;
      nabu.image.compress = false;
      fileSystems = lib.genAttrs (builtins.attrNames config.nabu.image.mountPaths) (_: {
        device = lib.mkForce "/dev/vda";
      });
      virtualisation = {
        # Keep the storage profile's fileSystems rather than qemu-vm defaults.
        fileSystems = lib.mkForce { };
        useDefaultFilesystems = false;
        mountHostNixStore = false;
        useNixStoreImage = false;
        diskImage = "disk.qcow2";
        memorySize = 1536;
      };
      users.users.nabu = {
        isNormalUser = true;
        initialPassword = lib.mkDefault "nabu";
        hashedPasswordFile = lib.mkIf (variant == "impermanent") "/nix/persistent/nabu-password";
      };
      # Test our manifest service rather than qemu-vm's regInfo boot parameter.
      systemd.services.register-nix-paths.script = lib.mkForce (
        (import ../nixos/images/registration.nix { inherit config lib; })
        .systemd.services.register-nix-paths.script
      );
    }
  );

  testScript = { nodes, ... }: ''
    import subprocess

    images = {
        "ext4": "${nodes.ext4.system.build.rootfs-image}/nabu-rootfs.ext4.img",
        "impermanent": "${nodes.impermanent.system.build.rootfs-image}/nabu-rootfs.btrfs.img",
    }
    for machine in [ext4, impermanent]:
        subprocess.run([
            "${pkgs.qemu}/bin/qemu-img", "create", "-f", "qcow2", "-F", "raw",
            "-b", images[machine.name], str(machine.state_dir / "disk.qcow2"), "4G",
        ], check=True)
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.fail("journalctl -b --no-pager | grep 'Activation script snippet.*failed'")
        machine.succeed("systemctl is-active register-nix-paths.service")
        machine.succeed("test ! -e /nix/persistent/nix-path-registration")
        machine.succeed("nix-store --query --requisites /run/current-system")
        machine.succeed("test -L /nix/var/nix/profiles/system")

    ext4.succeed("test $(findmnt -n -o FSTYPE /) = ext4")
    ext4.succeed("test $(df -B1 --output=size / | tail -1) -gt 3500000000")
    impermanent.succeed("test $(findmnt -n -o FSTYPE /) = tmpfs")
    impermanent.succeed("test $(findmnt -n -o FSTYPE /nix) = btrfs")
    impermanent.succeed("test $(df -B1 --output=size /nix | tail -1) -gt 3500000000")
    impermanent.succeed("test $(stat -c %u:%g /home/nabu) = 1000:100")
    impermanent.succeed("touch /ephemeral-marker /home/nabu/kept /nix/persistent/kept")
    original_password = impermanent.succeed("getent shadow nabu | cut -d: -f2")
    impermanent.succeed("echo nabu:changed-password | chpasswd")
    password = impermanent.succeed("getent shadow nabu | cut -d: -f2")
    assert password != original_password
    # Provision a private hash outside the store, as documented for this profile.
    impermanent.succeed("(umask 077; getent shadow nabu | cut -d: -f2 > /nix/persistent/nabu-password)")
    machine_id = impermanent.succeed("cat /etc/machine-id")
    impermanent.shutdown()
    impermanent.start()
    impermanent.wait_for_unit("multi-user.target")
    impermanent.fail("journalctl -b --no-pager | grep 'Activation script snippet.*failed'")
    impermanent.fail("test -e /ephemeral-marker")
    impermanent.succeed("test -e /home/nabu/kept && test -e /nix/persistent/kept")
    assert impermanent.succeed("getent shadow nabu | cut -d: -f2") == password
    assert impermanent.succeed("cat /etc/machine-id") == machine_id
    impermanent.succeed("nix-store --query --requisites /run/current-system")
    impermanent.succeed("test ! -e /nix/persistent/nix-path-registration")
    impermanent.fail("systemctl --failed --no-legend | grep .")
  '';
}
