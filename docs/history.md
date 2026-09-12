**English** | [简体中文](zh_CN/history.md)

# Project history and credits

[Back to project home](../README.md)

This project builds on the work of
[Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu). The
original author established the NixOS porting skeleton for nabu, organised the
kernel, firmware and device packages, and pushed the rootfs image and early boot and
display adaptation, providing the foundation for a system that later became usable on
hardware. Those contributions and their commit history are preserved in this
repository.

The early approach borrowed the boot and hardware configuration of Fedora for Nabu,
using rEFInd and a UKI to package the kernel, initrd, DTB and command line. It gave
NixOS a starting point that could be built, delivered and debugged further. Later
branches gradually completed device validation, desktop integration and a boot
architecture rework.

The branch currently maintained by hybrid-orbital chooses systemd-boot, using
nixpkgs' native external DTB and NixOS generation support, and publishes a niri +
Noctalia image. The goal has moved on from early boot exploration towards a
maintainable device system, desktop experience, configuration variants and
continuous builds. Changed technical trade-offs do not invalidate the exploratory
value of the early approach at that time, nor do they mean the original author or
other upstream projects make any support commitment for the current release of this
branch.

## Upstream projects and resources

- [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu): the original NixOS port and image foundation.
- [Mooling0602/nabu-nixos-kde-config](https://github.com/Mooling0602/nabu-nixos-kde-config): related NixOS work on nabu; this repository defines the current desktop and boot implementation.
- [jhuang6451/nabu_fedora](https://github.com/jhuang6451/nabu_fedora): image, kernel configuration, device service and hardware adaptation references.
- [nabu_fedora_packages](https://github.com/jhuang6451/nabu_fedora_packages): device packages and boot resources; this repository pins the corresponding resource fork's revision and hash in `boot.nix`.
- [sm8150-mainline/linux](https://gitlab.com/sm8150-mainline/linux): SM8150 mainline kernel development.
- [Project Aloha](https://github.com/Project-Aloha/mu_aloha_platforms): device UEFI firmware.
- [rodriguezst/nabu-dualboot-img](https://github.com/rodriguezst/nabu-dualboot-img): nabu dual-boot work.
- [GopRotate](https://github.com/apop2/GopRotate): EFI display rotation driver.
- [nabu-firmware](https://gitlab.postmarketos.org/panpanpanpan/nabu-firmware): device firmware packaging source.
- [NixOS / nixpkgs](https://github.com/NixOS/nixpkgs) and [systemd](https://github.com/systemd/systemd): the configuration system and native boot management.
- [niri](https://github.com/niri-wm/niri) and [Noctalia](https://github.com/noctalia-dev/noctalia-shell): the current desktop and shell.
- map220v, timoxa0, nik012003, panpantepan, and the community contributors who continue to adapt and test Linux on nabu.

## Using the historical material

[`MEMORY.md`](legacy/MEMORY.md) keeps early porting and build notes and does not
describe the current state. The old UKI test path and the QEMU script belong to
earlier approaches and should not be used as installation steps for the current
release. Current instructions are the [installation guide](installation.md), the
[build guide](building.md) and [device usage](usage-on-device.md).

The configuration and scripts are licensed under [LICENSE](../LICENSE). The kernel,
firmware, drivers and other imported components retain their own licences; their
origin and licence information should be preserved when referencing or packaging
them.
