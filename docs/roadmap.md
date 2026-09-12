**English** | [简体中文](zh_CN/roadmap.md)

# Roadmap

[Back to project home](../README.md)

The current baseline is the released, maintainer-verified systemd-boot + niri +
Noctalia image. The aim of the work below is to make nabu easier to build,
maintain and use day to day, staying close to NixOS' way of composing modules, boot
management and configuration. These are directions and acceptance criteria, not
features that already exist or committed release dates.

## Builds and cross compilation

- Improve the x86_64 → aarch64 entry points, dependency hints and error localisation.
- Keep recording cross-build problems with the pinned nixpkgs and desktop
  components, distinguishing "evaluates", "builds" and "boots".
- Evaluate ARM64 native builders and binary caches to reduce the first on-device
  rebuild cost.
- Record `buildPlatform`/`hostPlatform`, commit, lock file, build method and the
  scope of on-device validation in the release notes.

Acceptance: a clean environment can build as documented; failures come with clear
localisation; the store-path differences and resource cost between a cross-built
image and a native rebuild are actually recorded, rather than promising that
cross-platform caches are interchangeable.

## System configuration and image size

- First record the compressed download size, the uncompressed rootfs size and the
  system closure size, and analyse where the main dependencies come from.
- Reduce unnecessary packages, firmware or indirect build dependencies while keeping
  the necessary recovery tools and diagnostic ability.
- Split the common hardware/boot modules from the desktop choice and add separate
  TTY, niri + Noctalia and KDE configurations.
- Validate cold boot, reboot, growth and routine updates of the new tmpfs root +
  Btrfs image on the tablet.
- Complete the Impermanence persistence list and recovery procedures, and record the
  scope of on-device validation.

Acceptance: every variant offered publicly has real flake outputs, a matching
ESP/rootfs, size records and a stated validation scope. ext4 and Btrfs already have
separate filesystem-image build backends and mount configuration; see the
[storage profile](storage.md) guide. Impermanence is also not the same as automatic
backup or generation-based data rollback, so the boundaries of recovery and
persistence should be documented separately.

## Device support and power management

- Investigate the occasional boot failures and build a regression record for cold
  boots, warm reboots and display takeover.
- Validate how the stable Wi-Fi MAC address after reboot (already solved by deriving
  it from the SMBIOS serial, approach from TwinbornPlate75/linux-nabu) affects DHCP
  reservations and network admission.
- Implement usable power-key behaviour: define what locking, screen-off, low-power
  suspend and wake-up each do.
- Validate wake sources, display resume, touch/pen and network recovery, and measure
  real standby power consumption.
- Push the camera and the remaining unvalidated hardware, evaluating more kernel
  options and device tree adjustments.
- Keep every candidate kernel/driver change revertible and avoid changing a large
  number of unrelated parameters at once.

Acceptance: repeated suspend/wake and boot tests are recorded, power is measured, and
the failure cause and affected hardware version are clear. A single success, a
successful lock, or having a kernel option enabled does not amount to a finished
feature.

## CI and release infrastructure

- Build GitHub Actions in stages: first configuration evaluation, documentation
  links, KDL and script checks, then image builds.
- Choose a suitable ARM64 native runner or cross-build environment, and manage
  caching, disk space and build duration.
- Set up a build matrix for the planned configuration variants, recording which
  platforms are not supported yet.
- Automatically export images, `SHA256SUMS`, split archives, and source/lock
  information, and verify the reassembled artifacts.
- Update the old QEMU smoke script so it tests the current separate
  kernel/initrd artifacts.
- Record on-device regression results and automated build results separately, and
  state clearly whether a release has been validated on hardware.

Acceptance: PR checks and tag releases have traceable logs, and the downloaded files
can be reassembled and verified completely. QEMU does not emulate nabu's real UEFI,
UFS, display or power paths and cannot replace on-device acceptance.

## Documentation and collaboration

- Keep the English and Chinese front pages in sync, and maintain the installation,
  build, update, device-status and architecture documentation.
- Update feature status, known issues, asset names, flash targets and verification
  methods on every release.
- Provide configuration examples, migration boundaries, rollback methods and test
  records for new variants.
- Keep historical troubleshooting notes separate from current instructions, and
  preserve the contributions of the original author and the upstream community.
- Complete the English versions of the detailed guides; all guides are now bilingual.

See the [contribution guide](../CONTRIBUTING.md) (Chinese) for how to take part.
