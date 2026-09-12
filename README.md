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

## Storage variants

Two storage profiles are available out of the box. Both reuse the existing GPT
`esp` and `linux` partitions and do not repartition the device:

- **`ext4-nabu` (default, host name `nabu`)**: a conventional ext4 root
  filesystem, suitable for general and everyday use.
- **`impermanent-nabu`**: the more aggressive tmpfs-root profile, aimed at Nix
  users who want a stateless root with declarative persistence. `/` is tmpfs
  (capped at 25% of RAM) while `/nix`, `/nix/persistent` and `/home` live in
  subvolumes of the same Btrfs partition, so only the root directory is discarded
  on reboot. The repository already provides a btrfs image target for it
  (`nabu-rootfs.btrfs.img`), which still needs hardware validation.

Directory layout, the persistence list, declarative passwords and migration are
covered in the [storage guide](docs/storage.md).

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
| Low-power suspend | s2idle is reachable and no longer wakes immediately (Bluetooth UART wake fixed and validated on hardware); power key, auto-suspend and standby power still pending |
| Power key | Deliberately ignored pending usable screen-off and suspend/resume support |
| Boot reliability | Boot sometimes fails; the cause is still under investigation |
| Wi-Fi hangs after idle | After long idle, ath10k_snoc detects an unresponsive firmware/WMI, recovery fails repeatedly, and Wi-Fi stops working until the driver is reloaded (still under long-term observation) |

Other hardware needs fuller test records; enabling a driver in the
configuration is not evidence of hardware validation. When reporting a problem,
include the image version, firmware version, reproduction steps and logs;
distinguish cold boots from warm reboots.

### Fixed or mitigated

The random Wi-Fi MAC address across reboots is now resolved: the generic
board-2.bin carries no MAC, so a kernel patch
(`pkgs/kernel/patches/0002-nabu-ath10k-mac-address.patch`) derives a stable
locally-administered address from the SMBIOS board serial, overridable with the
`ath10k_core.macaddr=` module parameter. The approach comes from
[TwinbornPlate75/linux-nabu](https://github.com/TwinbornPlate75/linux-nabu).

**Suspend-to-idle waking immediately** — fixed, and entering suspend has been
confirmed on hardware.

- **Main cause**: the Bluetooth UART (`uart13` / `c8c000.serial`) port stays open
  across system sleep, so the GENI serial runtime-suspend callback never runs, the
  sleep pinctrl is never applied and the QUP13 pads stay in their `bias-disable`
  default state; combined with the TLMM latching edges while the wake IRQ is
  masked, that IRQ fires the moment it is armed.
- **Fix**: backport upstream `d0cd9c8d0fd5` ("serial: qcom-geni: add force
  suspend/resume to system sleep callbacks"), which forces the runtime suspend
  from the system-sleep callbacks; patch:
  `pkgs/kernel/patches/0005-qcom-geni-serial-force-suspend-system-sleep.patch`.
- **Credit**: upstream author **Praveen Talari** (Qualcomm), merged via tty-next
  for v6.18-rc4 and absent from 6.17.y.
- **Caveats**: this is a backport onto the 6.17 branch. Bluetooth operation and the
  wake capability are unchanged, but merging upstream later should confirm the fix
  has been absorbed.

<details><summary>Technical details</summary>

The WCN3991 Bluetooth UART is a serdev whose port stays open, so the runtime PM
usage count never reaches zero at suspend time (the PM core additionally pins a
reference during prepare). `qcom_geni_serial_runtime_suspend()` therefore never
runs and `geni_se_resources_off()` is skipped, which also skips the sleep pinctrl
(`qup_uart13_sleep`: GPIO input with a `gpio46` pull-up). The controller's traffic
produces falling edges, and pinctrl-msm latches edge-IRQ status while the IRQ is
masked, so the dedicated wake IRQ fired as soon as `dpm_suspend_noirq` armed it and
the system resumed immediately. The patch keeps the upstream author, commit message
and sign-off chain, with only the diff context rebased.

</details>

**Wi-Fi hangs after a long idle period (`ath10k_snoc` / WCN3990)** — root cause
identified, upstream fix backported, still under long-term observation.

- **Main cause**: `ath10k` runs its recovery check synchronously on the QMI
  indication path and queues the recovery work on the ordered workqueue, where
  later triggers are coalesced. Recoveries therefore never actually run while
  still consuming consecutive-failure credits, until the device is marked `WEDGED`
  and `ath10k_start()` fails permanently (the `WARN_ON` in `mac.c` is the symptom,
  not the root cause).
- **Fix**: backport upstream `f35a07a4842a` ("wifi: ath10k: move recovery check
  logic into a new work"), which moves the check to its own workqueue and cancels
  it in `ath10k_stop()`; patch:
  `pkgs/kernel/patches/0004-nabu-ath10k-recovery-check-workqueue.patch`.
- **Credit**: upstream author **Kang Yang** (Qualcomm). The firmware version is
  unrelated (firmware is loaded via TQFTP and is already HL 3.2.0).
- **Caveats**: the backport has not seen a long enough observation period yet. If
  Wi-Fi hangs again the driver must be re-probed (restarting NetworkManager alone
  does not help); reload it manually to recover:

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

<details><summary>Root-cause details</summary>

`ath10k` marks the device `WEDGED` because of recoveries that never actually run:
the check executes synchronously on the QMI indication path
(`ath10k_snoc_fw_indication()`), blocking for up to 5 seconds waiting for the
previous recovery to finish, and then queues `restart_work` on the ordered
workqueue, where later triggers are coalesced. Every trigger therefore only
consumes a consecutive-failure credit, after which `ath10k_start()` keeps failing
even though the interface was down.

</details>

### Provided now and planned work

**Provided now**

- Native systemd-boot generations and an Android boot entry
- niri + Noctalia desktop and greeter; landscape boot menu, greeter, desktop and pen mapping
- ext4 images, plus an experimental tmpfs root + Btrfs variant
- Native ARM64 and x86_64 cross-build entry points; local image export script

**Planned work**

- **Builds and caches:** improve cross-build entry points and diagnostics, track
  compatibility, and explore native ARM64 builders and binary caches to reduce the
  first on-device rebuild cost.
- **System and image size:** measure dependencies, shrink the rootfs and split
  common device modules from the TTY, niri and KDE configurations; validate the
  Btrfs/Impermanence variant on hardware and document recovery.
- **Device support:** investigate intermittent boot failures, work on cameras, and
  implement usable power-key behaviour, screen-off and low-power suspend/resume
  with measured standby power.
- **CI and releases:** build GitHub Actions evaluation checks and image builds,
  improve caching, checksums, split archives and release records, and report
  automated builds and hardware validation separately.
- **Documentation and contributions:** keep both READMEs, installation steps and
  device status aligned; document reproducible usage and validation for new
  variants, and translate the detailed guides.

These are planned tasks. Targets are tracked in the
[roadmap](docs/roadmap.md), and what is implemented and validated
in [device status](docs/device-status.md). Separate TTY/KDE outputs
and automated image CI are not available yet. Contributions with configuration
details, logs and validation results are welcome; see the
[contribution guide](CONTRIBUTING.md) (Chinese).

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

If these partitions cannot be queried or accessed, check the device mode and
layout before continuing. Do not guess other partition names. On first boot the
rootfs grows to the existing `linux` partition size.

At the Noctalia greeter, both the default username and initial password are **`nabu`**.
For ext4, run `passwd` after login; the impermanent profile uses
[declarative passwords](docs/storage.md#passwords-for-the-impermanent-profile). **TTY autologin and SSH password authentication are also
enabled**; adjust the configuration for ongoing personal use. Changing the password
does not disable TTY autologin.

Use `systemctl --failed` to inspect failed services,
`findmnt /boot/efi` to check the ESP mount, and `bootctl list` to inspect boot entries.

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
[architecture](docs/architecture.md) for implementation details.

## On-device updates and rollback

Keep a checkout on the tablet. To start a personal configuration from this release:

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
# Pick any branch name; the starting point can be a release tag
# (v0.1.0-alpha, later releases, ...) or another branch such as main
git switch -c my-nabu v0.1.0-alpha
```

After editing, use `git add` for new files so the Git flake can read them.
Update from the checkout:

```sh
# Routine update: without a #name the configuration is chosen by host name
# (the ext4 variant's host name is nabu)
sudo nixos-rebuild switch --flake .

# Variants can also be selected explicitly: nabu for ext4, impermanent-nabu
# for the stateless root variant
sudo nixos-rebuild switch --flake .#nabu
sudo nixos-rebuild switch --flake .#impermanent-nabu
```

`switch` updates boot entries and activates the configuration. Kernel, initrd and
boot-parameter changes require a reboot. Use `sudo nixos-rebuild boot --flake .#nabu`
to prepare only the next boot.

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
[updates and rollback](docs/usage-on-device.md) for details.

To migrate while preserving data from an existing installation, do not flash the
rootfs: back up first, then deploy and verify the new boot entry with an on-device
`nixos-rebuild boot`. The [installation guide](docs/installation.md)
covers migration and first boot.

## Build

The repository's `nixos/configuration.nix` already adds
`https://nix-nabu.cachix.org` to `nix.settings.extra-substituters` (together with
the matching `extra-trusted-public-keys`). That cache prebuilds
`nixosConfigurations.nabu.config.system.build.kernel` among other outputs, so a
plain `nixos-rebuild` on the tablet usually does not recompile the kernel. To
build on another Nix machine (including a cross-build host), add both settings
there:

```nix
nix.settings.extra-substituters = [ "https://nix-nabu.cachix.org" ];
nix.settings.extra-trusted-public-keys = [
  "nix-nabu.cachix.org-1:6oBp/ANDnp5za8MMMfz6EpkJbN1jaRlRpPIoKL4tCGM="
];
```

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
[build guide](docs/building.md) for details. The export script writes to a
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
and native caches can still be reused.

The flake exposes cross-build entry points, but cross compilation is not
guaranteed to succeed: different platforms may need different overrides of
nixpkgs. When a native aarch64-linux builder or an existing cache is available,
select the native ARM64 outputs with `nix build .#packages.aarch64-linux.<...>`,
which picks the flake output's system instead of cross compiling.

The flake currently produces an uncompressed rootfs; the zstd compression and
splitting in releases are additional packaging steps. The old
`scripts/qemu-smoke.sh` has not been adapted to the current non-UKI outputs and is
not a test entry point for this release. See the [build guide](docs/building.md)
for more troubleshooting and measurement notes.

## Further reading

The detailed guides are available in English under `docs/` and in Chinese under
`docs/zh_CN/`. Archived material is in `docs/legacy/`.

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

### Kernel patch sources

The changes in `pkgs/kernel/patches/` come from the authors and upstream commits
below; this repository only backports and adapts them:

- **`0001-nabu-match-fedora-runtime-fixes.patch`**: downstream fixes from the
  sm8150 mainline fork, by **Nicola Guerrera** (commits `53a8b558`, `01fc3dd3`,
  `6963e380`).
- **`0001-drm-msm-dsi-Move-MI_DRM_BLANK_UNBLANK-notification-t.patch`**: by
  **TwinbornPlate75** `<3342733415@qq.com>`, commit `bc048e06`.
- **`0002-nabu-ath10k-mac-address.patch`**: approach from
  [TwinbornPlate75/linux-nabu](https://github.com/TwinbornPlate75/linux-nabu).
- **`0003-nabu-adreno-do-not-abort-system-suspend.patch`**: approach adapted from
  the iris VPU5 suspend fix in `CFM880/nabu-iris` (`42085a8`).
- **`0004-nabu-ath10k-recovery-check-workqueue.patch`**: upstream `f35a07a4842a`
  ("wifi: ath10k: move recovery check logic into a new work") by **Kang Yang**
  (Qualcomm).
- **`0005-qcom-geni-serial-force-suspend-system-sleep.patch`**: upstream
  `d0cd9c8d0fd5` ("serial: qcom-geni: add force suspend/resume to system sleep
  callbacks") by **Praveen Talari** (Qualcomm).

Further background is in [project history](docs/history.md).

## License

Project configuration and scripts are MIT-licensed; see [LICENSE](LICENSE).
The kernel, firmware, EFI programs and other third-party components retain their
respective licenses.
