#!/usr/bin/env bash
# Small round trips exercise real zstd streams, splitting, and integrity checks.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/esp" "$tmp/raw" "$tmp/compressed"
head -c 32768 /dev/urandom > "$tmp/esp/esp.img"
printf 'EFI fixture\n' > "$tmp/esp/efi-files.zip"
head -c 65536 /dev/urandom > "$tmp/raw/nabu-rootfs.ext4.img"
zstd --quiet "$tmp/raw/nabu-rootfs.ext4.img" \
  -o "$tmp/compressed/nabu-rootfs.btrfs.img.zst"

for kind in raw compressed; do
  out="$tmp/$kind-dist"
  SPLIT_SIZE=8K bash "$repo/scripts/package-images.sh" "$tmp/esp" "$tmp/$kind" "$out"
  (
    cd "$out"
    sha256sum -c SHA256SUMS
    parts=(*.part-*)
    [[ ${#parts[@]} -gt 1 ]]
    for part in "${parts[@]}"; do
      [[ $(stat -c %s "$part") -le 8192 ]]
    done
    raw_name=${parts[0]%.zst.part-*}
    zstd --quiet -d --sparse esp.img.zst -o esp.img
    cat "${parts[@]}" | zstd --quiet -d --sparse -o "$raw_name"
    sha256sum -c SHA256SUMS.images
    cmp "$raw_name" "$tmp/raw/nabu-rootfs.ext4.img"
    cmp esp.img "$tmp/esp/esp.img"
    # A corrupted download must fail the packaged checksums.
    printf 'corrupt' >> "${parts[0]}"
    if sha256sum -c SHA256SUMS > /dev/null 2>&1; then
      echo 'Corrupted part was accepted' >&2
      exit 1
    fi
  )
  if bash "$repo/scripts/package-images.sh" "$tmp/esp" "$tmp/$kind" "$out"; then
    echo 'Existing output directory was accepted' >&2
    exit 1
  fi
done

# Tiny outputs still have one consistently named part.
bash "$repo/scripts/package-images.sh" "$tmp/esp" "$tmp/raw" "$tmp/single"
parts=("$tmp/single/"*.part-*)
[[ ${#parts[@]} -eq 1 && ${parts[0]} == *.part-0000 ]]

# Ambiguous inputs and invalid split sizes must fail.
cp "$tmp/raw/nabu-rootfs.ext4.img" "$tmp/raw/nabu-rootfs.btrfs.img"
if bash "$repo/scripts/package-images.sh" "$tmp/esp" "$tmp/raw" "$tmp/ambiguous"; then
  echo 'Ambiguous rootfs inputs were accepted' >&2
  exit 1
fi
if SPLIT_SIZE=invalid bash "$repo/scripts/package-images.sh" \
  "$tmp/esp" "$tmp/compressed" "$tmp/invalid"; then
  echo 'Invalid split size was accepted' >&2
  exit 1
fi
echo 'Packaging tests passed.'
