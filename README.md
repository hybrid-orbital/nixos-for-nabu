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

## Filesystem variants

Two filesystem profiles are available out of the box. Both use the
`esp` (as /boot) and `linux` (as /) partitions and do not repartition the device:

- **`ext4-nabu` (default, host name `nabu`)**: a conventional ext4 root
  filesystem, suitable for general and everyday use.
- **`impermanent-nabu`**: the more aggressive tmpfs-root profile, aimed at Nix
  users who want a stateless root with declarative persistence. `/` is tmpfs
  (capped at 25% of RAM) while `/nix`, `/nix/persistent` and `/home` live in
  subvolumes of the same Btrfs partition, so only the root directory is discarded
  on reboot.

Directory layout, the persistence list, declarative passwords and migration are
covered in the [storage guide](docs/storage.md).

## Current release

[**v2026.09.12.1.1**](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v2026.09.12.1.1),
at commit `51763f8`, is built and published by GitHub Actions on native ARM64.
It provides matching ESP/rootfs images for ext4 and tmpfs root + Btrfs, split
compressed archives, checksums and build records. This release includes suspend,
display wake and Wi-Fi fixes, along with touchscreen input and firmware size improvements.
A successful CI build does not establish hardware validation; full on-device
regression testing of the impermanent variant remains pending.

### Known issues

| Area | Current limitation |
| --- | --- |
| Wi-Fi hangs after long idle | ath10k_snoc detects unresponsive firmware/WMI and repeatedly fails recovery; Wi-Fi becomes unusable and requires a manual driver reload (still under long-term observation) |
| Low-power suspend | With the fixes, `systemctl suspend` enters s2idle; standby power consumption needs further measurement |
| Power key | For practical use, logind ignores the power key and leaves it to the desktop environment. Pressing it does not suspend the device, but can still wake it from suspend |
| Boot reliability | Occasional boot failures; cause under investigation |
| Speakers | The upper-right speaker is unavailable; popping may occur |
| Microphone | Not working yet |
| Cameras | Not working yet |


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

# Option 2: unload/reload the kernel module
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

### Planned work

- Provide configuration variants such as TTY, niri and KDE, and reduce rootfs size.
- Split the current configuration into NixOS modules and expose a hardware-only module through the flake for use in other projects.
- Investigate the remaining hardware issues.

These are planned tasks. Targets are tracked in the [roadmap](docs/roadmap.md),
and implemented and validated features in [device status](docs/device-status.md).
Separate TTY/KDE outputs are not available yet. Contributions with configuration
details, logs and validation results are welcome; see the
[contribution guide](CONTRIBUTING.md) (Chinese).


## Install a release image

Download all assets with your chosen variant's prefix (`ext4-nabu-` or
`impermanent-nabu-`) from the
[v2026.09.12.1.1 release](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v2026.09.12.1.1),
including the ESP image, all rootfs parts, checksums, `RESTORE.txt` and `BUILD-INFO.txt`.
`*-esp.zip` is an archive of ESP files for inspection or manual deployment,
not a partition image. Use matching ESP and rootfs images from the same release
and filesystem variant. The commands below use ext4; for the impermanent variant,
replace every `ext4-nabu-` prefix with `impermanent-nabu-`.

This repository **does not build Aloha UEFI / DBKP or partition the device**.
These steps require a nabu with a working Aloha/dual-boot environment, Secure Boot
disabled, and existing `esp` and `linux` partitions. `esp` is the FAT EFI system
partition mounted at `/boot/efi`; `linux` holds the ext4 or Btrfs filesystem.
Flashing overwrites existing ESP and Linux data. Back up first and check partition sizes.

Place all assets for your variant in one directory, verify the downloads,
reassemble and decompress the rootfs, then verify the raw images:

```sh
sha256sum -c ext4-nabu-SHA256SUMS
cat ext4-nabu-rootfs.image.zst.part-* | zstd -d --sparse -o ext4-nabu-rootfs.image
sha256sum -c ext4-nabu-SHA256SUMS.images
```

Allow disk space for the parts and decompressed image. The device partition must
fit the **decompressed image**. Confirm that all checksums pass and check partition
capacity against the actual image sizes. Enter a fastboot environment that supports
this layout, verify the device and partitions, then flash:

```sh
fastboot devices
fastboot getvar partition-size:esp
fastboot getvar partition-size:linux
fastboot flash linux ext4-nabu-rootfs.image
fastboot flash esp ext4-nabu-esp.image
fastboot reboot
```

If these partitions cannot be queried or accessed, check the device mode and
layout before continuing. Do not guess other partition names. On first boot the
ext4 or Btrfs filesystem grows to the existing `linux` partition size.


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
# (v2026.09.12.1.1, later releases, ...) or another branch such as main
git switch -c my-nabu v2026.09.12.1.1
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

### Binary cache

The repository's `nixos/configuration.nix` includes the Cachix binary cache
`https://nix-nabu.cachix.org`. GitHub Actions builds and caches
`nixosConfigurations.nabu.config.system.build.kernel`, so an on-device
`nixos-rebuild` usually does not need to recompile the kernel.

To build on another Nix machine (including a cross-build host), consider adding
these settings to its configuration:

```nix
nix.settings.extra-substituters = [ "https://nix-nabu.cachix.org" ];
nix.settings.extra-trusted-public-keys = [
  "nix-nabu.cachix.org-1:6oBp/ANDnp5za8MMMfz6EpkJbN1jaRlRpPIoKL4tCGM="
];
```

### Flake outputs

On Linux with Nix and flakes enabled, check out the repository and run:

```sh
# Kernel (the second command always selects the native ARM64 configuration)
nix build .#nabu-kernel
nix build .#nixosConfigurations.nabu.config.system.build.kernel

# ext4 ESP files and image, and rootfs image
nix build .#ext4-nabu-esp
nix build .#nabu-esp       # Alias of ext4-nabu-esp
nix build .#ext4-nabu-rootfs
nix build .#nabu-rootfs    # Alias of ext4-nabu-rootfs

# Btrfs + tmpfs root
nix build .#impermanent-nabu-esp
nix build .#impermanent-nabu-rootfs

# System closures (native ARM64 configurations)
nix build .#nixosConfigurations.impermanent-nabu.config.system.build.toplevel
nix build .#nixosConfigurations.ext4-nabu.config.system.build.toplevel
```

Build the ESP and rootfs with the same source, `flake.lock`, configuration and
build platform. Keep these inputs unchanged during the build.

**Cross compilation**

On `x86_64-linux`, `nix build .#nabu-kernel` and the shorthand image outputs above
select x86_64 → aarch64 cross compilation. On `aarch64-linux`, they select native
builds. Different `buildPlatform` values and build dependencies normally produce
different derivations and store paths. The first native rebuild on the tablet
may rebuild the kernel and many packages unless matching native outputs or caches
are available.

The cross-build entry points were a workaround when the project only had an
`x86_64-linux` build machine. They are not guaranteed to keep working as nixpkgs
changes and may need extra overrides. The current flake has no `aarch64-darwin`
package outputs; on Apple Silicon, an `aarch64-linux` VM or remote Linux builder
can build native outputs.

Select native ARM64 package outputs explicitly with:

```sh
nix build .#packages.aarch64-linux.nabu-kernel
```

This selects the output platform but does not configure a builder. Building
requires an `aarch64-linux` builder, or emulation enabled on a NixOS Linux host
with `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`. If all outputs are
already cached, no local compilation is needed.

See the [build guide](docs/building.md) for details.


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

The changes in `pkgs/kernel/patches/` include upstream backports and local
adaptations. Verified sources are listed below:

- **`0001-nabu-match-fedora-runtime-fixes.patch`**: a combined patch introduced by
  repository commit [`f1a0391`](https://github.com/hybrid-orbital/nixos-for-nabu/commit/f1a039140353fad1d336751e42c95a530056e5ba).
  Disabling Hall-sensor wake, correcting the touchscreen `getClient(void)` declarations,
  and removing the uninitialized idtp9418 variable and log match **Nicola Guerrera**'s
  upstream commits
  [`53a8b558`](https://gitlab.com/sm8150-mainline/linux/-/commit/53a8b55839d1cd4be6dc25f11aeb93e8348cc270),
  [`01fc3dd3`](https://gitlab.com/sm8150-mainline/linux/-/commit/01fc3dd3c8317362bcddd9eab9f243909621a4a0), and
  [`6963e380`](https://gitlab.com/sm8150-mainline/linux/-/commit/6963e3800a8e8059c5f01b01dd8e2a5e6a28209a),

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
