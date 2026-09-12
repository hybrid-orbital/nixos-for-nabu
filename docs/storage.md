**English** | [简体中文](zh_CN/storage.md)

# Storage profiles and images

[Back to project home](../README.md)

The repository provides two storage profiles; both use the niri + Noctalia desktop:

| Profile | `/` | Persistent data | Image |
| --- | --- | --- | --- |
| `ext4-nabu` (the default configuration of `nabu`) | ext4 | conventional root filesystem | `nabu-rootfs.ext4.img` |
| `impermanent-nabu` | tmpfs, capped at 25% of RAM | subvolumes of one Btrfs partition | `nabu-rootfs.btrfs.img` |

The Btrfs variant is a new, experimental profile: cold boot, reboot and day-to-day
updates still need validation on the tablet. The automated tests use a generic
kernel and do not emulate nabu's UEFI, UFS or display hardware.

## Layout and retained data

Both profiles use the existing GPT `esp` and `linux` partitions and do not
repartition the device. The ESP is always mounted at `/boot/efi`. The
impermanent profile's `linux` partition is:

```text
Btrfs top level
├── @nix        → /nix
├── @persistent → /nix/persistent
└── @home       → /home

tmpfs           → /
```

`/nix` is retained as a whole, including the store, database, profiles and GC
roots; `/home` is retained as a whole, so user-editable niri configuration and
personal files survive a reboot. `/nix/persistent` is mounted from a separate
subvolume even though it lives under `/nix`.

System state is mapped by
[impermanence](https://github.com/nix-community/impermanence): machine-id, SSH
host keys, NetworkManager/iwd configuration, Bluetooth pairings, system logs, the
NixOS/systemd state that is required, and `/root`. The exact list is in
[`storage/impermanent.nix`](../nixos/storage/impermanent.nix). Accounts are
rebuilt declaratively through `users.mutableUsers = false`; passwords are covered
below.

Everything else in the root directory is discarded on reboot. Packages and user
data are not stored in tmpfs, but temporary data written to the root directory
does consume memory. The impermanent profile moves the Nix build temporary
directory to `/nix/var/nix/builds` through `nix.settings.build-dir`, so large
rebuilds do not fill up tmpfs.

The impermanent root provides no backup of user data and does not create Btrfs
snapshots automatically. NixOS generation rollback only rolls back the system
configuration and closures, not persistent data.

## Custom persistent directory

Set this in a module imported by the impermanent configuration:

```nix
nabu.storage.persistentDirectory = "/persist";
```

This updates the subvolume mount point, the impermanence paths and the location of
the registration manifest together. The default manifest path is
`${config.nabu.storage.persistentDirectory}/nix-path-registration`. You can also
set `nabu.image.registrationPath` separately, but it must be inside a persistent
mount covered by the image and must not be placed in `/nix/store`. The builder
resolves the location inside the image by longest matching mount point, so a
nested `/nix/persistent` is not mistakenly placed in `@nix`.

Changes to the image configuration apply to new installations. When changing the
persistent directory on an existing system, deal with the existing mounts,
references and data as well; `nixos-rebuild switch` is not an automatic migration
tool.

## Passwords for the impermanent profile

The initial username and password are still `nabu`. This profile does not keep
`passwd` changes to `/etc/shadow`: a reboot or re-activation of the configuration
restores the declared password. The conventional ext4 profile keeps using
`passwd`.

To set a private password, first write the hash into the persistent directory on
the tablet (adjust the path if you customised it):

```sh
sudo install -d -m 0700 /nix/persistent/passwords
nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt | sudo sh -c 'umask 077; cat > /nix/persistent/passwords/nabu'
```

Then declare it in a module of the system configuration and run
`nixos-rebuild switch --flake .#impermanent-nabu`:

```nix
{ config, ... }: {
  users.users.nabu.hashedPasswordFile =
    "${config.nabu.storage.persistentDirectory}/passwords/nabu";
}
```

The hash file is read by activation and is not copied into the Nix store. The file
must exist before the setting is enabled; when it is missing there is no fallback
to the public default password. Changing the password later only requires updating
that file and re-activating the configuration.

## Building and installing

```sh
# Default ext4 pair
bash scripts/build-image.sh all ext4

# Matching ESP and Btrfs pair
bash scripts/build-image.sh all impermanent
```

You can also build `.#impermanent-nabu-esp` and `.#impermanent-nabu-rootfs`
directly. Every configuration provides `config.system.build.esp-image` and
`config.system.build.rootfs-image`. The initrd and system paths inside the ESP
change with the configuration, so the ESP and rootfs must be built as a pair.

After confirming that the existing partitions are large enough and that backups
are done, the flash targets for the Btrfs profile are still:

```sh
fastboot flash linux nabu-rootfs.btrfs.img
fastboot flash esp esp.img
```

Switching from ext4 to Btrfs is a reinstall and overwrites the `linux` partition,
including the user data it contains. The new image is also not an update package
that preserves existing persistent data; day-to-day updates use
`sudo nixos-rebuild boot --flake .`. The system host name corresponds to the flake
key/alias (ext4 is `nabu`, impermanent is `impermanent-nabu`), so omitting
`#hostname` still selects the installed profile; use `--flake .#impermanent-nabu`
when you want to be explicit.

## Boot, registration and growth

The initrd mounts the tmpfs root, `/nix`, the persistent subvolume and `/home`
according to `fileSystems`, and then enters system initialisation. The kernel
configuration check requires Btrfs and tmpfs to be built in. The image creates the
source directories for the persistent bind mounts in advance, so the first boot
does not fail to mount before activation.

The image contains the system closure and the initial profile link. On first boot,
`register-nix-paths.service` reads the manifest from the configured location, runs
`nix-store --load-db` before the nix-daemon starts, and sets the system profile;
the manifest is deleted only after both steps succeed. Later boots use the
persistent database directly. The manifest is written by the image builder and is
not placed inside the system closure itself, to avoid a circular dependency.

Both profiles grow the filesystem to the existing partition size with
`x-systemd.growfs`. For Btrfs, growth is scheduled on `/nix` only; the other
subvolumes of the same filesystem share the grown space. The initrd explicitly
includes the growfs unit and program. `boot.growPartition`, `sgdisk` and
repartitioning at boot are not used; a `linux` partition that is too small still
has to be handled by the user before installation.

Check the following on first boot and after one reboot:

```sh
findmnt -t tmpfs,btrfs
df -h /nix
sudo btrfs filesystem usage /nix
systemctl --failed
journalctl -b -u register-nix-paths.service --no-pager
nix-store --query --requisites /run/current-system
```

Confirm that temporary files in the root directory are gone while user files, the
declared password, machine-id and network configuration are retained.

## Builder and checks

After copying the system closure, the builder produces standalone filesystem
images with `mke2fs -d` or `mkfs.btrfs --rootdir --subvol`; it does not need to
mount the image or run a VM. For Btrfs it uses a user namespace to make the owners
inside the image root, so the build environment must allow unprivileged user
namespaces. It uses 4 KiB filesystem sectors, and the features currently enabled
by default in mkfs are suitable for the repository's Linux 6.17 kernel.

When creating the Btrfs image, the pre-installed closure is compressed with
`--compress zstd:15`, unused image space is then shrunk with `--shrink`, and the
deployment headroom given by `nabu.image.rootFsExtraSize` is appended last. The
growfs on first boot folds that headroom and the remaining capacity of the target
partition into the filesystem. At runtime `compress=zstd` continues to be used.
`nabu.image.compress` controls only the outer `.zst` packaging of the image and
does not affect the compression inside these filesystems.

```sh
nix flake check --no-build --all-systems
nix build .#checks.x86_64-linux.filesystem-images
nix build .#checks.x86_64-linux.storage-boot
```

The first build check uses a small closure and verifies image metadata, subvolumes,
custom paths and the Nix DB contents. The second one boots a generic NixOS test
machine and covers first-boot registration, growth, temporary-file cleanup after a
reboot and state retention. The boot test allows QEMU software emulation and is
slower without KVM.
