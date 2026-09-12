#!/usr/bin/env bash
# Historical UKI-only helper: not compatible with current systemd-boot outputs.
# See docs/zh_CN/building.md; adapting this helper is tracked in docs/zh_CN/roadmap.md.
# Boot the shipped kernel/initrd with copies of both flashable partitions.
# QEMU supplies a virt DTB; the embedded nabu DTB is only usable on hardware.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo "usage: $0 UKI.efi ROOTFS.ext4.img ESP.img" >&2
  echo "Requires qemu-system-aarch64, aarch64-unknown-linux-gnu-objcopy, sfdisk, debugfs." >&2
  exit 1
fi
uki=$(realpath "$1")
rootfs=$(realpath "$2")
esp=$(realpath "$3")
objcopy=${OBJCOPY:-aarch64-unknown-linux-gnu-objcopy}
for tool in "$objcopy" qemu-system-aarch64 sfdisk debugfs; do
  command -v "$tool" >/dev/null
done
work=$(mktemp -d /tmp/nabu-qemu-smoke.XXXXXX)
echo "Test disk and serial log: $work"
"$objcopy" --dump-section .linux="$work/Image" \
  --dump-section .initrd="$work/initrd" \
  --dump-section .cmdline="$work/cmdline" "$uki" "$work/inspect.efi"
cmdline=$(tr -d '\000' < "$work/cmdline")
image_init=$(debugfs -R 'cat /init' "$rootfs" 2>/dev/null)
case " $cmdline " in
  *" init=$image_init "*) ;;
  *) echo 'UKI init= does not match rootfs /init' >&2; exit 1 ;;
esac
# 4 KiB logical sectors, like nabu; leave extra space to test x-systemd.growfs.
esp_sectors=$(( ($(stat -c %s "$esp") + 4095) / 4096 ))
root_start=$(( (256 + esp_sectors + 255) / 256 * 256 ))
root_sectors=$(( ($(stat -c %s "$rootfs") + 4095) / 4096 + 65536 ))
truncate -s "$(( (root_start + root_sectors + 256) * 4096 ))" "$work/disk.raw"
sfdisk --sector-size 4096 "$work/disk.raw" <<EOF
label: gpt
start=256, size=$esp_sectors, type=U, name=esp
start=$root_start, size=$root_sectors, type=L, name=linux
EOF
dd if="$esp" of="$work/disk.raw" bs=4096 seek=256 conv=notrunc,sparse status=none
dd if="$rootfs" of="$work/disk.raw" bs=4096 seek="$root_start" conv=notrunc,sparse status=none
exec qemu-system-aarch64 \
  -machine virt,gic-version=3 -cpu cortex-a72 -smp 4 -m 2048 \
  -display none -monitor none \
  -chardev "stdio,id=console,logfile=$work/serial.log,signal=off" \
  -serial chardev:console \
  -kernel "$work/Image" -initrd "$work/initrd" \
  -append "$cmdline console=ttyAMA0,115200" \
  -drive "if=none,file=$work/disk.raw,format=raw,id=disk" \
  -device virtio-blk-device,drive=disk,logical_block_size=4096,physical_block_size=4096 \
  -netdev user,id=net -device virtio-net-device,netdev=net
