# Kernels

One directory per kernel.  Each directory is a self-contained package and is
listed once in [`default.nix`](default.nix):

```text
pkgs/kernel/<name>/default.nix   the kernel derivation
pkgs/kernel/<name>/patches/      downstream patches, applied in order
pkgs/kernel/<name>/configs/      kconfig fragment + required settings
```

The directory name is also the kernel's name in
[`default.nix`](default.nix), in the flake package outputs
(`.#nabu-kernel-<name>`) and in the `nabu.kernel.name` NixOS option — pick one
with:

```sh
nix build .#nabu-kernel-mainline-latest      # build that kernel only
nixos-rebuild switch --flake .#ext4-nabu --option nabu.kernel.name mainline-latest
```

or, for a checkout of this repository:

```nix
# nixos/configuration.nix (or a local module)
{ lib, ... }: {
  nabu.kernel.name = lib.mkForce "mainline-latest";
}
```

## Available kernels

| Name | Source | Notes |
| --- | --- | --- |
| `sm8150-fork` | sm8150-mainline/linux `v6.17.0-sm8150` | Default.  The pinned downstream tree, built from its own `sm8150.config` defconfig; `patches/` only carries the nabu runtime fixes. |
| `mainline-latest` | nixpkgs `linux_latest` | nixpkgs' stock kernel plus `patches/`, a rebase of the downstream nabu support (device tree, panel, touchscreen, sound card, charging, runtime fixes) that is not upstream yet. |

`sm8150-fork` is the known-good kernel for the device.  `mainline-latest`
tracks upstream and is the kernel under test: it is expected to gain the
remaining downstream drivers as they are rebased, and to eventually replace
the fork once it is verified on hardware.

### Status of `mainline-latest`

Verified so far:

- every patch in `patches/` applies to a pristine nixpkgs `linux-7.2.3` tree
  with no fuzz and no rejects;
- kconfig resolves with our fragment (`configs/nabu.config`); on arm64 an
  option kconfig cannot satisfy is a build error, so this also checks the
  fragment itself;
- `arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb` compiles with `dtc`;
- the flake evaluates (`nix flake check --no-build --all-systems`) and
  `sm8150-fork` keeps its existing store path, so the published cache still
  applies to the default kernel.

Not verified yet: a complete `nix build .#nabu-kernel-mainline-latest` (the
first attempt was stopped by a full disk on the local Linux builder, before it
reached the end) and, of course, booting the device with it.  The CI kernel
workflow builds and caches it, so the next step is to let that run and then
flash the resulting generation.

Still downstream-only, i.e. worth checking on the device: the Wi-Fi/Bluetooth
firmware path, camera and sensor drivers, and anything that depends on the
sm8150-specific clock/interconnect tables that upstream keeps changing.

## Adding a kernel

1. Create `pkgs/kernel/<name>/` with `default.nix`, `patches/` and `configs/`.
2. Regenerate the patches from the downstream tree you are rebasing (see the
   header of `mainline-latest/default.nix` for the workflow that was used).
3. Add one line to `default.nix` (the registry).  Everything else — the
   overlay (`pkgs.kernel-*`), the flake package `.#nabu-kernel-<name>`, the
   `nabu.kernel.name` option and the CI matrix — picks it up automatically.

## Required settings

Each kernel ships `configs/required-nabu.config`, a list of settings that must
be present verbatim in the resolved `.config`.  `postConfigure` greps for them,
so a kernel update or a patch rebase that silently drops a driver needed to
reach the root filesystem or to light the panel fails the build instead of
failing on the device.  Keep the file free of settings that kconfig may resolve
to the other value (`m` vs `y`).
