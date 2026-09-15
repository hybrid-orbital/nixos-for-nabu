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

Not verified yet: booting the device with it.  The CI kernel workflow builds
and caches both kernels, so the next step is to run it and then flash the
resulting generation.

Worth checking first on the device: display bring-up and the DSI blank
notifier handshake with the touchscreen, charging (the `pm8150b`/SMB5 path
plus the `idtp9418` wireless charger), audio routing through the WCD9340 sound
card, and the Wi-Fi/Bluetooth firmware path.

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
