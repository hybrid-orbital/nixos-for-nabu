# Registry of the kernels this project ships.
#
# One directory per kernel, each self-contained (source/version choice,
# patches, kconfig fragment and the required-config assertion), so a new
# kernel version is added by dropping in a directory and adding one line here:
#
#   pkgs/kernel/<name>/default.nix    the kernel derivation
#   pkgs/kernel/<name>/patches/       downstream patches, applied in order
#   pkgs/kernel/<name>/configs/       kconfig fragment + required settings
#
# The attribute names are the keys used by `nabu.kernel.name` in the NixOS
# configuration (see nixos/hardware-nabu.nix) and by the CI workflows.
#
#   sm8150-fork      pinned sm8150-mainline fork (v6.17.0-sm8150), built from
#                    its own downstream defconfig
#   mainline-latest  nixpkgs linux_latest + the downstream nabu patches
{ callPackage }:

{
  "sm8150-fork" = callPackage ./sm8150-fork { };
  "mainline-latest" = callPackage ./mainline-latest { };
}
