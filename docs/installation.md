**English** | [简体中文](zh_CN/installation.md)

# Installation and first boot

[Back to project home](../README.md)

The current release is
[v0.1.0-alpha](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha).
The maintainer has verified the niri + Noctalia desktop and the systemd-boot
generation menu. The camera is still unavailable and boots occasionally fail (the
random Wi-Fi MAC address issue is resolved, and suspend-to-idle is reachable again
after the Bluetooth UART immediate-wake fix). See
[device status](device-status.md).

## Target device and existing environment

This project only targets the Xiaomi Pad 5 (nabu). It produces the rootfs and the
ESP, **does not build Aloha UEFI or DBKP images** and does not partition the
device. The steps below assume a working Aloha/dual-boot environment, Secure Boot
disabled, and a partition layout matching
[`nixos/hardware-nabu.nix`](../nixos/hardware-nabu.nix):

| Partition label | Purpose | Linux mount point |
| --- | --- | --- |
| `esp` | FAT EFI system partition holding systemd-boot and boot files | `/boot/efi` |
| `linux` | ext4 NixOS root filesystem | `/` |

Do not assume the existing partition layout is correct just because the device
model matches. Flashing replaces existing Linux data and ESP contents, including
older distributions and custom boot configurations; back up first. The image keeps
the Android boot entry, but it does not back up Android or other data, and
compatibility with arbitrary third-party firmware and partition layouts is not
guaranteed.

## Download and reassemble

`v0.1.0-alpha` provides:

- `esp.img`: a 350105600-byte ESP partition image.
- `efi-files.zip`: an archive of the files inside the ESP, for inspection or
  manual deployment; not a partition image.
- `nabu-rootfs.ext4.img.zst.part00` and `nabu-rootfs.ext4.img.zst.part01`: the two
  parts of the compressed rootfs.

Place both parts in one directory, reassemble them in order, then decompress:

```sh
cat nabu-rootfs.ext4.img.zst.part00 nabu-rootfs.ext4.img.zst.part01 > nabu-rootfs.ext4.img.zst
zstd -t nabu-rootfs.ext4.img.zst
zstd -d nabu-rootfs.ext4.img.zst
```

Allow space for the parts, the combined archive and the decompressed image. The
compressed size is not the partition size the device needs. `zstd -t` checks
compressed-stream integrity and is not a substitute for a trusted release
checksum; this release ships no `SHA256SUMS`, while the local
`scripts/build-image.sh` generates one—run `sha256sum -c SHA256SUMS` in that
directory when using such artifacts. Do not mix ESP and rootfs from different
versions.

## Flash to the existing partitions

Enter a fastboot environment that supports this layout, verify the device and the
partition sizes, then flash:

```sh
fastboot devices
fastboot getvar partition-size:esp
fastboot getvar partition-size:linux
fastboot flash linux nabu-rootfs.ext4.img
fastboot flash esp esp.img
fastboot reboot
```

**This is `fastboot flash esp esp.img`, not `fastboot flash boot esp.img`.** The
`boot` in the initial `v0.1.0-alpha` release notes was a typo; `boot` is the
partition used by the firmware/Android boot chain, and the ESP image must not be
written there. These commands only apply to devices confirmed to have `linux` and
`esp` partitions. If fastboot cannot query or access those partitions, check the
device mode and layout first; do not guess other partition names.

The current rootfs grows ext4 to the existing `linux` partition size through
`x-systemd.growfs`; it does not modify the GPT and cannot enlarge a partition that
is too small. This procedure switches the ESP fallback entry to systemd-boot;
rEFInd is no longer used.

An optional tmpfs root + Btrfs image is also available; see the
[storage guide](storage.md) for how to build, install and
update it. The release installation steps on this page keep using the
conventional ext4 variant.

## First boot

1. systemd-boot shows the NixOS and Android entries; the initial image has a
   single NixOS generation.
2. Log in at the Noctalia greeter and then into niri. The default user is `nabu`
   and the initial password is `nabu`.
3. The first boot registers the Nix store database; use `nixos-rebuild` for
   day-to-day updates afterwards.
4. Change the password and confirm that networking and logs work:

```sh
passwd
systemctl --failed
findmnt /
findmnt /boot/efi
bootctl list
cat /proc/cmdline
```

The current configuration enables both TTY autologin and SSH password
authentication. When deploying this as a long-term personal system, adjust
autologin, SSH access and user settings in the configuration; changing the
password alone does not disable TTY autologin.

Landscape orientation for the boot menu, greeter and desktop is configured
separately; see the [desktop notes](desktop.md). The camera is
still unavailable and the power key is deliberately ignored; suspend-to-idle is
reachable again, but locking the screen does not mean the system entered a
low-power state.

## Migrating from an old UKI/rEFInd installation

Flashing the rootfs is a reinstall and overwrites existing Linux data. To keep an
existing NixOS installation, back up the ESP, record the working boot entries and
the current system configuration first, then build and deploy this release on the
device:

```sh
sudo nixos-rebuild boot --flake .#nabu
```

Before rebooting, check `bootctl list`, the systemd-boot entries on the ESP and
the Android files. Old UKIs and rEFInd configuration may still be present on the
ESP; do not assume the new installer removes files it does not manage. Verify that
the new system boots and can roll back before cleaning up by reference order. See
the [build notes](building.md) for the cost of moving from a
cross-built image to a native rebuild.

## Validation and reporting

Before a release and when testing a new device, record whether the menu is
usable, whether the desktop can be logged into, whether a new generation appears
after one update, whether a retained older generation can be selected, and whether
the Android entry works. Record cold boots, warm reboots and repeated boots
separately; one success does not mean intermittent boot problems are solved.

On failure, collect data as described in [boot diagnostics](boot-logging.md).
A black screen or a reboot alone is not enough to attribute the fault
to the DTB, signatures, the display driver or the rootfs.
