#!/usr/bin/env bash
# Build a matching set of flashable nabu images using native cross compilation.
# Usage: bash scripts/build-image.sh [all|esp|rootfs] [ext4|impermanent]
# OUT_DIR may name a new output directory; existing artifact files are rejected.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-all}
variant=${2:-ext4}
case "$mode" in all|esp|rootfs) ;; *)
  echo "usage: $0 [all|esp|rootfs] [ext4|impermanent]" >&2; exit 1 ;;
esac
case "$variant" in ext4|impermanent) ;; *)
  echo "Unknown storage variant: $variant" >&2; exit 1 ;;
esac
mkdir -p result-images
OUT_DIR=${OUT_DIR:-$(mktemp -d "$PWD/result-images/build-XXXXXX")}
mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")
for name in esp.img efi-files.zip nabu-rootfs.{ext4,btrfs}.img{,.zst} SHA256SUMS; do
  if [ -e "$OUT_DIR/$name" ]; then
    echo "Refusing to overwrite $OUT_DIR/$name; select a new OUT_DIR." >&2
    exit 1
  fi
done

if [ "$mode" != rootfs ]; then
  nix build ".#$variant-nabu-esp" --out-link "$OUT_DIR/nix-esp"
  cp --reflink=auto --sparse=always "$OUT_DIR/nix-esp/esp.img" "$OUT_DIR/esp.img"
  cp "$OUT_DIR/nix-esp/efi-files.zip" "$OUT_DIR/efi-files.zip"
fi
if [ "$mode" = all ] || [ "$mode" = rootfs ]; then
  nix build ".#$variant-nabu-rootfs" --out-link "$OUT_DIR/nix-rootfs"
  shopt -s nullglob
  rootfs=("$OUT_DIR"/nix-rootfs/nabu-rootfs.*.img "$OUT_DIR"/nix-rootfs/nabu-rootfs.*.img.zst)
  if [ "${#rootfs[@]}" -ne 1 ]; then
    echo "Expected exactly one rootfs image in $OUT_DIR/nix-rootfs" >&2
    exit 1
  fi
  cp --reflink=auto --sparse=always "${rootfs[0]}" "$OUT_DIR/"
fi
(
  cd "$OUT_DIR"
  artifacts=()
  for name in esp.img efi-files.zip nabu-rootfs.{ext4,btrfs}.img{,.zst}; do
    if [ -f "$name" ]; then artifacts+=("$name"); fi
  done
  sha256sum "${artifacts[@]}" > SHA256SUMS
)
echo "Artifacts: $OUT_DIR"
ls -lh "$OUT_DIR"
