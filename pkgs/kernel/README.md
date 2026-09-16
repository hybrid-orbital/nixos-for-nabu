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
(`.#nabu-kernel-<name>`) and in the `nabu.kernel.name` NixOS option.

Building one kernel needs no system closure — this is the cheap way to check a
patch rebase or a configuration change:

```sh
nix build .#nabu-kernel-mainline-latest
nix build .#nabu-kernel-sm8150-fork
```

`nabu.kernel.name` is an ordinary NixOS option (an enum of the names registered
in `default.nix`), so choosing the kernel for the *system* means setting it in
configuration like any other option:

```nix
# nixos/configuration.nix, or a module of your own
{
  nabu.kernel.name = "mainline-latest";
}
```

```sh
sudo nixos-rebuild switch --flake .#ext4-nabu
```

Two things to keep in mind:

- `nixos-rebuild --option` is **not** how this option is set.  That flag passes
  Nix settings (such as `substituters`) through to Nix itself.
- A git flake only sees tracked files, so a new module file has to be
  `git add`ed before `nixos-rebuild` can see it.

To try a kernel without editing the repository at all, override the option
while building the system and activate that store path (the previous
generations, with the other kernel, stay bootable):

```sh
nix build --impure --expr '
  let f = builtins.getFlake (toString ./.);
  in (f.nixosConfigurations.ext4-nabu.extendModules {
       modules = [ { nabu.kernel.name = "mainline-latest"; } ];
     }).config.system.build.toplevel'
sudo nixos-rebuild switch --store-path "$(readlink -f result)"
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

Verified:

- every patch in `patches/` applies to a pristine nixpkgs `linux-7.2.3` tree
  with no fuzz and no rejects;
- kconfig resolves with our fragment (`configs/nabu.config`); on arm64 an
  option kconfig cannot satisfy is a build error, so this also checks the
  fragment itself;
- `nix build .#nabu-kernel-mainline-latest` completes: `Image`,
  `dtbs/qcom/sm8150-xiaomi-nabu.dtb` and the nabu modules are all built
  (`nt36523_ts`, `panel-novatek-nt36523`, `ktz8866`, `msm`, `ufs-qcom`,
  `qcom_fg`, `idtp9418`, `qcom_smbx`, `ath10k_snoc`, `snd-soc-sm8150`,
  `snd-soc-cs35l41-i2c`, ...), and the `postConfigure` check passes against
  the resolved `.config`;
- the flake evaluates (`nix flake check --no-build --all-systems`) and
  `sm8150-fork` keeps its existing store path, so the published cache still
  applies to the default kernel.

The first on-device boot of this kernel stopped right after the EFI stub
handed over: grey screen, no output, no response.  Two port defects caused it,
both fixed since:

- **The device tree lost the `refgen` regulator.**  Upstream 7.2.3 already has
  `refgen: regulator@88e7000` plus the `refgen-supply` links on both DSI
  controllers, while the downstream tree carries its own copy of that node
  (from a time when upstream did not have it).  Rebuilding the port from the
  downstream tree ended up *deleting* upstream's node, and the msm DSI host
  then silently falls back to a dummy regulator (`dsi_host.c` does a mandatory
  `devm_regulator_bulk_get_const()` of `{ vdda, refgen }`), so REFGEN is never
  enabled and the panel shows nothing.  Since arm64 has no EFI framebuffer
  handover, that removes the only console the device has — which is why the
  boot looked like a hang.
- **The initramfs was missing boot-critical modules.**  The 6.17 fork kernel
  builds the UFS controller, its QMP PHY, DRM/MSM and the REFGEN regulator in;
  `mainline-latest` gets them as modules from nixpkgs' common config.  The
  QMP UFS PHY is matched through the device tree, not through a symbol
  dependency, so it was not pulled into the initramfs automatically and
  `ufs_qcom_init()` returned `-EPROBE_DEFER` forever: the root filesystem
  never appeared.  `nixos/hardware-nabu.nix` now lists `phy_qcom_qmp_ufs`,
  `qcom_refgen_regulator`, `phy_qcom_qmp_combo` and `typec`, and
  `configs/nabu.config` builds the pstore backends in so a boot that still
  fails leaves its log in the ramoops region.

Verified after the fix: the patch series still applies to a pristine tree with
no rejects, the kernel builds, the *built* DTB contains the `refgen` node and
both `refgen-supply` links, and the *built* initramfs contains
`phy-qcom-qmp-ufs`, `qcom-refgen-regulator`, `ufs-qcom`, `ufshcd-core/pltfrm`,
`msm`, `panel-novatek-nt36523`, `ktz8866`, `phy-qcom-qmp-combo` and `typec`
(37 modules in total).

Still not verified: a successful boot.  If the next on-device attempt fails
again, the log is at `/sys/fs/pstore/console-ramoops-0` — boot the working
`sm8150-fork` generation and read it there; that is what the pstore settings
above are for.

The rebase also needed three API updates that are folded into the patches: the
nabu panel init sequence passes the DSI multi-context by address (upstream has
that helper as a macro, the downstream tree had its own value-argument one),
the nt36523 touchscreen looks its GPIOs up with the gpiod consumer API
(`of_gpio.h` is gone), and ath10k includes `<linux/hex.h>` for `mac_pton()`.

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
