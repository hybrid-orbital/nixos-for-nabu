**English** | [简体中文](README_zh_CN.md)

# NixOS for Nabu

A buildable, updatable NixOS system for the **Xiaomi Pad 5 (nabu)**. The current
boot architecture uses **systemd-boot with separate kernel, initrd and device
tree files**, native NixOS generation menus, and a **niri + Noctalia** desktop.

This project continues the porting work of
[Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu).
The original repository established the NixOS configuration, kernel and device
packages, and bootable NixOS images with the infrastructure to build them.
This fork builds on that foundation through validation, native Nixpkgs boot
management and everyday desktop use. This project depends on the work and
contributions of many other projects, credited below.

Storage variants and persistence settings: [storage guide](docs/storage.md) (Chinese).

## Current release

[**v0.1.0-alpha**](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha),
at commit `c26c2c1`, formally adopts systemd-boot as the boot architecture.
The maintainer has verified systemd-boot, the generation menu and the niri + Noctalia
image on hardware. More thorough testing is still needed; this does not mean
that every hardware feature is supported.

### Known issues

| Area | Current limitation |
| --- | --- |
| Camera | Not working |
| Low-power suspend | Not working; locking or blanking the display does not establish low-power operation |
| Power key | Deliberately ignored pending usable screen-off and suspend/resume support |
| Boot reliability | Boot sometimes fails; the cause is still under investigation |
| Wi-Fi MAC address | A new random address is selected on every reboot; it does not remain stable across boots |
| Wi-Fi hangs after idle | After long idle, ath10k_snoc detects an unresponsive firmware/WMI, recovery fails repeatedly, and Wi-Fi stops working until the driver is reloaded (cause located, upstream fix backported, on-device validation pending) |
| Image size | The rootfs is large; reducing the closure and splitting configurations are priorities |

The changing Wi-Fi MAC address may affect MAC-based DHCP reservations and network
access rules. The behavior is confirmed, but its cause and a fix have not been
verified. Other hardware needs fuller test records; enabling a driver in the
configuration is not evidence of hardware validation. When reporting a problem,
include the image version, firmware version, reproduction steps and logs;
distinguish cold boots from warm reboots.

Wi-Fi may hang after a long idle period: `ath10k_snoc` (WCN3990) detects an
unresponsive firmware/WMI, attempts automatic recovery, and after repeated
failures gives up (wedged state), leaving Wi-Fi unusable. The `WARN_ON` in
`mac.c` is the symptom, not the root cause: the recovery bookkeeping in
`ath10k` could mark the device `WEDGED` because of recoveries that never ran
(the check ran synchronously on the QMI indication path and queued its work on
the ordered workqueue, where later triggers were coalesced, so every trigger
merely consumed a consecutive-failure credit), and `ath10k_start()` then fails
permanently even though the interface was down. Upstream commit `f35a07a4842a`
("wifi: ath10k: move recovery check logic into a new work") runs the check on
its own workqueue and cancels it in `ath10k_stop()`; it is backported here as
`pkgs/kernel/patches/0004-nabu-ath10k-recovery-check-workqueue.patch`. The
firmware version is unrelated (firmware is loaded via TQFTP and is already
HL 3.2.0). Until the backport has been validated on hardware, reload the
driver manually to recover:

```sh
# Option 1 (recommended): rebind the platform device, no extra tools needed
ls /sys/bus/platform/drivers/ath10k_snoc/          # check the device name (usually 18800000.wifi)
nmcli radio wifi off
echo 18800000.wifi | sudo tee /sys/bus/platform/drivers/ath10k_snoc/unbind
echo 18800000.wifi | sudo tee /sys/bus/platform/drivers/ath10k_snoc/bind
nmcli radio wifi on

# Option 2: unload/reload the kernel module (modprobe is not on the default PATH; run `nix shell nixpkgs#kmod` first)
sudo systemctl stop NetworkManager
sudo modprobe -r ath10k_snoc
sudo modprobe ath10k_snoc
sudo systemctl start NetworkManager
```

Restarting NetworkManager alone does not recover; the driver must be re-probed
(unbind/bind or module reload).

### Available and planned features

| Available now | Planned work |
| --- | --- |
| Native systemd-boot generations and an Android entry | Smaller images and stronger release validation |
| niri + Noctalia desktop and greeter | Separate TTY and KDE configurations |
| Flashable ext4 images and an experimental tmpfs root + Btrfs variant | Hardware validation of persistence and recovery |
| Native ARM64 and x86_64 cross-build entry points | Cross-build compatibility and cache usability |
| Landscape boot menu, greeter, desktop and pen mapping | Screen-off, suspend/resume and remaining hardware support |
| Local image export script | GitHub Actions build and release infrastructure |

Cross-build entry points do not guarantee every configuration will build.
TTY and KDE variants are not available flake outputs yet. The experimental Btrfs
variant needs hardware validation. See
[device status](docs/device-status.md) and the [roadmap](docs/roadmap.md) (Chinese).

## Install a release image

Download `esp.img`, `nabu-rootfs.ext4.img.zst.part00` and
`nabu-rootfs.ext4.img.zst.part01` from the
[v0.1.0-alpha release](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha).
`efi-files.zip` is an archive of ESP files for inspection or manual deployment,
not a partition image.

This repository **does not build Aloha UEFI / DBKP or partition the device**.
These steps require a nabu with a working Aloha/dual-boot environment, Secure Boot
disabled, and existing `esp` and `linux` partitions. `esp` is the FAT EFI system
partition mounted at `/boot/efi`; `linux` is the ext4 root partition. Flashing
overwrites existing ESP and Linux data. Back up first and check partition sizes.

Place both rootfs parts in one directory, then reassemble and decompress:

```sh
cat nabu-rootfs.ext4.img.zst.part00 nabu-rootfs.ext4.img.zst.part01 > nabu-rootfs.ext4.img.zst
zstd -t nabu-rootfs.ext4.img.zst
zstd -d nabu-rootfs.ext4.img.zst
```

Allow disk space for the parts, combined archive and decompressed image. The device
partition must fit the **decompressed image**. The ESP image is 350105600 bytes.
This release has no `SHA256SUMS` asset; `zstd -t` only checks compressed-stream integrity.
Enter a fastboot environment that supports this layout, verify the device and
partitions, then flash:

```sh
fastboot devices
fastboot getvar partition-size:esp
fastboot getvar partition-size:linux
fastboot flash linux nabu-rootfs.ext4.img
fastboot flash esp esp.img
fastboot reboot
```

**Flash the ESP to `esp`, never `boot`. The early release instructions contain
a typo, `fastboot flash boot esp.img`.** If these partitions cannot be queried or
accessed, check the device mode and layout before continuing. Do not guess other
partition names. On first boot, ext4 grows to the existing `linux` partition size;
the partition table is not changed.

At the Noctalia greeter, both the default username and initial password are **`nabu`**.
For ext4, run `passwd` after login; the impermanent profile uses
[declarative passwords](docs/storage.md#无状态版本的密码). **TTY autologin and SSH password authentication are also
enabled**; adjust the configuration for ongoing personal use. Changing the password
does not disable TTY autologin. Use `systemctl --failed` to inspect failed services,
`findmnt /boot/efi` to check the ESP mount, and `bootctl list` to inspect boot entries.

To preserve data from an existing NixOS installation, avoid flashing the rootfs.
Back up first, then deploy and verify the new boot entry with an on-device
`nixos-rebuild boot`. The [installation guide](docs/installation.md) (Chinese)
provides migration details.

## Boot and generations

```text
Project Aloha UEFI / existing DBKP boot environment
  → systemd-boot (EFI/BOOT/BOOTAA64.EFI)
    → NixOS generation
      → matching kernel + initrd + external DTB + init=<generation>/init
        → ext4 rootfs → Noctalia greeter → niri
    → Android entry
```

NixOS manages boot deployment with `boot.loader.systemd-boot.enable = true`
and `installDeviceTree = true`. Generations can share unchanged boot files.
There is no per-generation UKI, custom previous-kernel copy, or mutable profile
path shared by all boot entries. Each entry's `init=` points to that generation's
specific Nix store system closure, and old entries retain their matching boot files.
External DTB loading works with the tested firmware with Secure Boot disabled;
a UKI is no longer necessary to deliver the device tree.

The project's `system.build.esp-image` code still assembles the initial ESP with one generation.
Subsequent rebuilds use the nixpkgs systemd-boot installer to deploy and manage
generations. Initial image files and old UKI/rEFInd files may not be cleaned up
automatically; check retained entries before deleting them. See
[architecture](docs/architecture.md) (Chinese) for implementation details.

## On-device updates and rollback

Keep a checkout on the tablet. To start a personal configuration from this release:

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
git switch -c my-nabu v0.1.0-alpha
```

After editing, use `git add` for new files so the Git flake can read them; a commit
is not required. Update from the checkout:

```sh
sudo nixos-rebuild switch --flake .#nabu
```

`switch` updates boot entries and activates the configuration. Kernel, initrd and
boot-parameter changes require a reboot. Use `sudo nixos-rebuild boot --flake .#nabu`
to prepare only the next boot. `flake.lock` pins dependencies; ordinary rebuilds
do not upgrade them. Run `nix flake update` when you intend to update inputs,
then build and validate.

If the system is still running, roll back to the previous generation with:

```sh
sudo nixos-rebuild switch --rollback
```

If a new generation fails to boot, select a retained older one in systemd-boot.
Use the volume keys to select an entry and the power key to confirm.
Manually selecting an entry does not permanently roll back the system profile;
inspect and roll back or repair the configuration after booting.
**Generation rollback does not restore user files or databases.**

Sharing boot files saves space, but distinct kernels and initrds still consume ESP
capacity. Set `boot.loader.systemd-boot.configurationLimit = 10;` in your configuration
to limit menu generations; this does not delete historical systems from the Nix store.
Keep a tested bootable generation before cleanup. See
[updates and rollback](docs/usage-on-device.md) (Chinese) for details.

## Build

On Linux with Nix and flakes enabled, create a checkout as shown above, then run:

```sh
# Keep both outputs on the same source, lock file and local configuration.
nix build .#nabu-esp .#nabu-rootfs

# Export matching images and SHA256SUMS to a fresh result-images directory.
# This script has not been tested; manually copying the nix build outputs
# to a location of your choice is recommended for now.
bash scripts/build-image.sh
```

The sole current NixOS configuration, `nixosConfigurations.nabu`, includes niri
and Noctalia. `nabu-esp`, `nabu-rootfs` and `nabu-kernel` have `x86_64-linux` and
`aarch64-linux` outputs; the default output is the ESP. See the
[build guide](docs/building.md) (Chinese) for details. The export script writes to a
fresh `result-images/build-*` directory and refuses to overwrite existing artifacts.
Build the ESP and rootfs together; do not mix revisions, configurations or native
and cross-built outputs. Keep the checkout and lock unchanged during the build,
and allow sufficient disk space, memory and network access or cached dependencies.

**Cross-build caveat:** x86_64 → aarch64 and native aarch64 builds have different
`buildPlatform` values and dependency graphs, normally producing different
derivations and store paths. Even after a cross-built image boots successfully,
the first native rebuild may rebuild the kernel and many packages. Cross-built
outputs are not a substitute for a native aarch64 binary cache. This follows from
different build inputs, not merely changing machines; matching existing outputs
and native caches can still be reused. Cross compilation may fail due to package
or toolchain compatibility. Successful evaluation is not proof of a successful
build or hardware boot. `--system aarch64-linux` selects native ARM64 outputs;
it does not configure cross compilation. Those outputs require an ARM64 builder,
matching cache or configured emulation.

The flake currently produces an uncompressed rootfs. Release zstd compression and
splitting are additional packaging steps. Compression reduces download size, not
the installed system closure. The old `scripts/qemu-smoke.sh` has not been adapted
to the current non-UKI outputs and is not a test entry point for this release.

## Next steps

- **Builds and caches:** improve cross-build commands and diagnostics, track compatibility,
  and explore native ARM64 builders and binary caches to reduce the first on-device rebuild cost.
- **System and image size:** measure large dependencies, shrink the rootfs and separate common
  device modules from TTY, niri and KDE configurations. Validate the new Btrfs/Impermanence
  variant on hardware and document recovery procedures.
- **Device support:** investigate intermittent boot failures and Wi-Fi MAC changes across
  reboots, work on cameras and kernel options, and implement usable power-key behavior,
  screen-off and low-power suspend/resume with measured standby power consumption.
- **CI and releases:** build GitHub Actions evaluation checks and image builds, improve caching,
  checksums, split archives and release records, and report hardware validation separately.
- **Documentation and contributions:** keep both READMEs, installation steps and device status
  aligned; document reproducible usage and validation for new variants, and translate detailed guides.

These are planned tasks. Separate TTY/KDE outputs and automated image CI are
not available yet. Contributions with configuration details, logs and validation
results are welcome. The [roadmap](docs/roadmap.md) and
[contribution guide](CONTRIBUTING.md) (Chinese) provide more detail.

## Further reading

Detailed guides currently use Chinese:

- [Installation and first boot](docs/installation.md)
- [Builds, cross compilation and caches](docs/building.md)
- [Boot architecture and generations](docs/architecture.md)
- [Updates, rollback and cleanup](docs/usage-on-device.md)
- [niri + Noctalia desktop](docs/desktop.md)
- [Device status](docs/device-status.md) · [Boot diagnostics](docs/boot-logging.md)
- [Roadmap](docs/roadmap.md) · [Contributing](CONTRIBUTING.md)
- [History and credits](docs/history.md)

## Acknowledgements

Thank you to **Mooling0602** for providing the configuration foundation, the
particularly important kernel and firmware packages, rootfs images, and early boot
and display adaptation for NixOS on the Xiaomi Pad 5. The current system builds on
these achievements. The rEFInd + UKI approach provided a convenient starting point
for further builds, debugging and hardware validation.

Linux on nabu also depends on sustained work across firmware, kernels, device
services and desktops:

- [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu) for the original NixOS port and image foundation.
- [Mooling0602/nabu-nixos-kde-config](https://github.com/Mooling0602/nabu-nixos-kde-config) for related NixOS work on nabu; this repository defines the current desktop and boot implementation.
- [jhuang6451/nabu_fedora](https://github.com/jhuang6451/nabu_fedora) for image, kernel configuration, device service and hardware adaptation references.
- [nabu_fedora_packages](https://github.com/jhuang6451/nabu_fedora_packages) for device packages and boot resources; this repository pins the corresponding resource fork's revision and hash in `boot.nix`.
- [sm8150-mainline/linux](https://gitlab.com/sm8150-mainline/linux) for SM8150 mainline kernel development.
- [Project Aloha](https://github.com/Project-Aloha/mu_aloha_platforms) for device UEFI firmware, and [rodriguezst/nabu-dualboot-img](https://github.com/rodriguezst/nabu-dualboot-img) for dual-boot work.
- [GopRotate](https://github.com/apop2/GopRotate) for EFI display rotation, and [nabu-firmware](https://gitlab.postmarketos.org/panpanpanpan/nabu-firmware) for device firmware packaging.
- [NixOS / nixpkgs](https://github.com/NixOS/nixpkgs) and [systemd](https://github.com/systemd/systemd) for the configuration system and native boot management.
- [niri](https://github.com/niri-wm/niri) and [Noctalia](https://github.com/noctalia-dev/noctalia-shell) for the current desktop and shell.
- map220v, timoxa0, nik012003, panpantepan, and the community contributors who continue to adapt and test Linux on nabu.

Further background is in [project history](docs/history.md) (Chinese).

## License

Project configuration and scripts are MIT-licensed; see [LICENSE](LICENSE).
The kernel, firmware, EFI programs and other third-party components retain their
respective licenses.
