**English** | [简体中文](zh_CN/building.md)

# Building, cross compilation and caches

[Back to project home](../README.md)

The build entry points are defined by the current [`flake.nix`](../flake.nix). To
reproduce a release image, check out the matching tag, keep `flake.lock` and record
local configuration changes; do not update inputs in the middle of building a
matching pair of images.

## Current outputs

| Output | Contents |
| --- | --- |
| `nixosConfigurations.nabu` / `ext4-nabu` | native ARM64 ext4 configuration with niri + Noctalia |
| `nixosConfigurations.impermanent-nabu` | tmpfs root + Btrfs persistence configuration |
| `packages.<system>.ext4-nabu-{esp,rootfs}` | matching images for the ext4 configuration |
| `packages.<system>.impermanent-nabu-{esp,rootfs}` | matching ESP and Btrfs images for the impermanent configuration |
| `packages.<system>.nabu-esp` | `esp.img` and `efi-files.zip` |
| `packages.<system>.nabu-rootfs` | `nabu-rootfs.ext4.img`, uncompressed by default |
| `packages.<system>.nabu-kernel` | the sm8150 kernel |
| `packages.<system>.default` | `nabu-esp` |

`<system>` supports `x86_64-linux` and `aarch64-linux`. There are no `nabu-uki`,
`nabu-kde` or `nabu-tty` outputs; the latter two are roadmap items.

The ext4 system's host name is `nabu` (an alias of `ext4-nabu`) and the impermanent
one is `impermanent-nabu`; both are flake keys or aliases, so
`sudo nixos-rebuild switch --flake .` automatically selects the configuration of
the installed storage profile without writing `#hostname` by hand.

## Building a matching image pair

You need Linux, Nix with flakes enabled, network access or a complete local
dependency cache, and enough disk space and memory. The resource requirements of
the desktop and kernel builds change with the configuration; do not treat disk
estimates from the historical minimal system as the current upper bound.

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
# Reproduce the current alpha; use your own branch when developing new configuration
git checkout v0.1.0-alpha
nix build .#nabu-esp .#nabu-rootfs
```

A more convenient export entry point:

```sh
bash scripts/build-image.sh
# or export only one kind of image
bash scripts/build-image.sh esp
bash scripts/build-image.sh rootfs
# matching images for the impermanent configuration
bash scripts/build-image.sh all impermanent
```

The script stores images and `SHA256SUMS` in a new `result-images/build-*`
directory, and `OUT_DIR` can point it at another new directory. It refuses to
overwrite existing artifacts. It builds the two outputs in sequence, so keep the
working tree unchanged while it runs. For CI builds, use the manual workflows below.

## Manual GitHub Actions builds

The Actions tab provides two `workflow_dispatch` workflows once their files are
on the default branch. Choose the same branch/tag (and unchanged commit) for both:

1. **Build kernel and push to Cachix** builds
   `.#nixosConfigurations.nabu.config.system.build.kernel` and explicitly uploads
   its closure to `nix-nabu`. First configure the repository Actions secret
   `CACHIX_AUTH_TOKEN` with write access to that cache. Missing credentials or a
   failed upload fail the job, including when the build itself was a cache hit.
2. **Build and package images** builds `.#ext4-nabu-esp`, `.#ext4-nabu-rootfs`,
   `.#impermanent-nabu-esp` and `.#impermanent-nabu-rootfs`, in two independent
   storage-variant jobs. It reads the public cache without a Cachix secret and
   uploads one Actions artifact per variant, retained for 14 days.

Both workflows use `ubuntu-24.04-arm` for native ARM64 derivations and explicitly
configure `extra-substituters` and `extra-trusted-public-keys` for the existing
`nix-nabu` cache. The image's NixOS settings do not configure the CI runner.
Run the kernel workflow successfully first to warm the cache; image builds can
still build missing dependencies. Cache reuse requires matching derivations,
including the kernel configuration and locked inputs. Neither workflow updates
`flake.lock`. Changing caches requires updating the URL/key in both workflows,
the kernel workflow's cache name, and its token.

Artifacts contain `esp.img.zst`, `efi-files.zip`, rootfs `.img.zst.part-0000`
parts, `SHA256SUMS`, `SHA256SUMS.images`, `RESTORE.txt` and `BUILD-INFO.txt`.
The latter records the commit, variant, platform, output store paths, Nix version
and lock-file hash. Download and extract the artifact, then follow `RESTORE.txt`:
verify the packaged checksums, concatenate the rootfs parts into the decompressor,
and verify the decompressed image checksums before flashing. Even a small rootfs
has a `.part-0000` file. Parts alone are neither zstd archives nor flashable images.

The reusable packaging command is:

```sh
bash scripts/package-images.sh /path/to/esp-output /path/to/rootfs-output ./dist
# Optional: override the default 1900 MiB part size with SPLIT_SIZE=1000M.
```

The output directory must not exist. Packaging streams zstd directly into `split`,
accepts either raw or already compressed rootfs outputs, verifies the compressed
streams, and avoids an extra raw rootfs copy or combined compressed file. Parts
are bundled into one Actions artifact per variant; splitting does not bypass the
repository's total artifact storage quota. Upload ZIP compression is disabled
because the images are already compressed.

Hosted runners have limited disk space and a six-hour job timeout. The image job
removes unused hosted SDK directories and limits concurrent Nix builds, but a
large closure or cold build may still need a larger ARM64 runner. Packaging reduces
export space, not the Nix store or temporary space needed to build the image.
The impermanent job allows unprivileged user namespaces in its disposable VM for
Btrfs image ownership, accounting for [Ubuntu 24.04's AppArmor restriction](https://documentation.ubuntu.com/release-notes/24.04/).
These workflows produce build artifacts; releases and on-device boot validation
remain separate steps. See the upstream [runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
and [artifact action](https://github.com/actions/upload-artifact) for platform and
artifact behavior.

See the [storage profile](storage.md) guide for the storage layout, custom
persistent directories and how to use the impermanent variant.

## Native and cross builds

Nix's platform naming is easy to confuse with the everyday "host/target" wording:

| Mode | `buildPlatform` (runs the build tools) | `hostPlatform` (runs the result) |
| --- | --- | --- |
| Native build on the tablet or an ARM64 Linux builder | aarch64-linux | aarch64-linux |
| Cross build from x86_64 Linux | x86_64-linux | aarch64-linux |

The current flake's x86_64 outputs set the cross-build platform; by design they do
not require running ARM64 build tools under QEMU. `--system aarch64-linux` only
selects the ARM64 outputs and does not configure a cross toolchain or an ARM64
builder. To use the native ARM64 outputs you need a native machine, a configured
remote ARM64 builder, or a separately configured emulation environment.

**Cross compilation is a build path worth trying, not a guarantee that every
package works.** Packages may run target programs at build time, depend on
toolchains that have not been adapted, or hit cross-specific problems after a
nixpkgs update. A passing `nix flake check --no-build --all-systems` only proves
that the respective checks evaluate; it does not mean the images can be built, let
alone that they boot on the tablet.

## Why a cross-built image is still rebuilt

Even though both cases target ARM64, cross and native builds have different
`buildPlatform` values, compilers and dependency graphs, which normally correspond
to different derivations and `/nix/store` paths. The difference comes from the
build inputs, not from changing machine or host name by itself; another native
builder with the same platform and inputs can still share the results.

A cross-built image runs normally. But when you run a native rebuild with
`nixosConfigurations.nabu` on the tablet, Nix needs the closure from the native
evaluation and may rebuild the kernel and a large number of packages. Existing
cross closures are not automatically treated as native closures. That can also
increase the time and disk usage of the first rebuild.

Not every package is necessarily rebuilt: native binary cache hits or matching
existing outputs are reused. A cross cache only helps matching cross derivations;
warming a cross image on a PC does not promise to speed up the tablet's native
rebuild. The manual workflows above use ARM64 native runners and a matching cache
to avoid this difference.

See the
[official Nix cross-compilation tutorial](https://nix.dev/tutorials/cross-compilation.html)
and the
[Nixpkgs cross-platform parameters](https://nixos.org/manual/nixpkgs/unstable/#ssec-cross-platform-parameters).

## Image size and compression

The ext4 image is sized as the system closure plus the
`nabu.image.rootFsExtraSize` headroom, 512 MiB by default. Btrfs first compresses
the pre-installed closure and shrinks the filesystem, then appends the same
headroom; see the [storage profile](storage.md) guide for details. The current
configuration sets `nabu.image.compress = false` so the image can be flashed
directly. The zstd compression and splitting in releases is release packaging and
differs from the flake's default outputs.

The outer zstd packaging only reduces the download size; the compression inside
Btrfs also reduces how much the pre-installed files occupy on the device. To shrink
the rootfs, first measure the closure of large dependencies, firmware, desktop
components and build tools, then decide how to split variants. On a build machine
you can inspect the default native configuration's closure first (running this
command on x86_64 does not silently switch to a cross configuration):

```sh
nix build .#nixosConfigurations.nabu.config.system.build.toplevel --out-link result-system
nix path-info -Sh ./result-system
```

This step needs working ARM64 build capability or a matching cache; do not trigger
a full build blindly on an unsuitable machine just to measure size. On a running
system, `nix path-info -Sh /run/current-system` records the closure size. Size
optimisation and the goals of each variant are tracked in the
[roadmap](roadmap.md).

## Reporting failures

Record the commit, the lock file, the build platform, the exact command, the
failing derivation and the build log; distinguish evaluation failures, build
failures, image-generation failures and on-device boot failures. Do not generalise
one success on one platform to every variant. The old `scripts/qemu-smoke.sh`
still requires a UKI and **does not apply to this release's artifacts**; updating
it is a pending task, and this guide does not list it as a validation method for
the current images.
