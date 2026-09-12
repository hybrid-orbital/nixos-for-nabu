#!/usr/bin/env bash
# Package Nix output directories without copying the uncompressed rootfs.
# Usage: bash scripts/package-images.sh ESP_OUTPUT ROOTFS_OUTPUT NEW_OUTPUT_DIR
# SPLIT_SIZE defaults to 1900 MiB; even small images use .part-0000 naming.
# RELEASE_VARIANT=ext4|impermanent exports separately named release assets.
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 3 ]]; then
  echo "usage: $0 ESP_OUTPUT ROOTFS_OUTPUT NEW_OUTPUT_DIR" >&2
  exit 1
fi
esp=$(realpath "$1")
rootfs=$(realpath "$2")
out=$3
split_size=${SPLIT_SIZE:-1900M}
prefix=
case ${RELEASE_VARIANT:-} in
  '') ;;
  ext4|impermanent) prefix="$RELEASE_VARIANT-nabu-" ;;
  *) echo 'RELEASE_VARIANT must be ext4 or impermanent.' >&2; exit 1 ;;
esac
shopt -s nullglob
images=("$rootfs"/nabu-rootfs.*.img "$rootfs"/nabu-rootfs.*.img.zst)
if [[ ! -f "$esp/esp.img" || ! -f "$esp/efi-files.zip" || ${#images[@]} -ne 1 ]]; then
  echo 'Expected esp.img, efi-files.zip and exactly one rootfs image.' >&2
  exit 1
fi
for tool in zstd split sha256sum; do
  command -v "$tool" > /dev/null
done
# Reject an existing directory, including incomplete output from a previous run.
mkdir -- "$out"
out=$(realpath "$out")
image=${images[0]}
raw_name=$(basename "${image%.zst}")
esp_name=esp.img
zip_name=efi-files.zip
if [[ -n "$prefix" ]]; then
  raw_name="${prefix}rootfs.image"
  esp_name="${prefix}esp.image"
  zip_name="${prefix}esp.zip"
fi

cp "$esp/efi-files.zip" "$out/$zip_name"
esp_asset="$esp_name.zst"
restore_esp="zstd -d --sparse $esp_asset -o $esp_name"
if [[ -n "$prefix" ]]; then
  esp_asset=$esp_name
  cp --reflink=auto --sparse=always "$esp/esp.img" "$out/$esp_asset"
  restore_esp="# $esp_name is already uncompressed."
else
  zstd -T2 -6 --no-progress --stdout "$esp/esp.img" > "$out/$esp_asset"
fi
if [[ "$image" == *.zst ]]; then
  split --bytes="$split_size" --numeric-suffixes=0 --suffix-length=4 \
    "$image" "$out/$raw_name.zst.part-"
else
  zstd -T2 -6 --no-progress --stdout "$image" |
    split --bytes="$split_size" --numeric-suffixes=0 --suffix-length=4 \
      - "$out/$raw_name.zst.part-"
fi

# Test the complete stream after splitting, not each individual part.
if [[ -z "$prefix" ]]; then zstd --test "$out/$esp_asset"; fi
cat "$out/$raw_name.zst.part-"* | zstd --test
if [[ "$image" == *.zst ]]; then
  raw_hash=$(zstd --decompress --stdout "$image" | sha256sum)
else
  raw_hash=$(sha256sum "$image")
fi
esp_hash=$(sha256sum "$esp/esp.img")
printf '%s  %s\n' "${esp_hash%% *}" "$esp_name" "${raw_hash%% *}" "$raw_name" \
  > "$out/${prefix}SHA256SUMS.images"
cat > "$out/${prefix}RESTORE.txt" <<EOF
Keep all files from this artifact in the same directory. Run there:

  sha256sum -c ${prefix}SHA256SUMS
  $restore_esp
  cat $raw_name.zst.part-* | zstd -d --sparse -o $raw_name
  sha256sum -c ${prefix}SHA256SUMS.images

Parts are numbered from 0000 and must be concatenated in lexical order.
Do not decompress or flash individual parts. No combined .zst file is needed.
Keep enough disk space for the decompressed images. Flash $esp_name to esp;
follow docs/installation.md for the rootfs and storage variant instructions.
EOF
(
  cd "$out"
  sha256sum "$esp_asset" "$zip_name" "$raw_name.zst.part-"* \
    "${prefix}SHA256SUMS.images" "${prefix}RESTORE.txt" > "${prefix}SHA256SUMS"
)
echo "Packaged images: $out"
