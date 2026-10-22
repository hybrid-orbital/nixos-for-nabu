#!/usr/bin/env bash
# Compile just FastRPC and PD mapper against an EXISTING matching kernel build.
# No Nix build, modules_prepare, download, installation or module loading.
# Usage: bash scripts/build-sensor-modules.sh KERNEL SOURCE BUILD OUTPUT
# KERNEL is sm8150-fork or mainline-latest. On x86, supply an arm64 toolchain
# through CROSS_COMPILE (or LLVM) and the compiler used by the kernel build.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# != 4 ]]; then
  echo "usage: $0 {sm8150-fork|mainline-latest} SOURCE BUILD OUTPUT" >&2
  exit 2
fi
case $1 in
  sm8150-fork) rpc_patch=0008-misc-fastrpc-nabu-sdsp-mappings.patch ;;
  mainline-latest) rpc_patch=0012-misc-fastrpc-nabu-sdsp-mappings.patch ;;
  *) echo "unknown kernel: $1" >&2; exit 2 ;;
esac
src=$(realpath -e "$2")
build=$(realpath -e "$3")
output=$(realpath -m "$4")
for f in .config Module.symvers include/config/kernel.release; do
  test -s "$build/$f" || { echo "missing prepared build file: $build/$f" >&2; exit 1; }
done
for cfg in CONFIG_ARM64=y CONFIG_QCOM_FASTRPC=m CONFIG_QCOM_PD_MAPPER=m; do
  grep -qx "$cfg" "$build/.config" || { echo "required: $cfg" >&2; exit 1; }
done
grep -Eq '^CONFIG_QCOM_PDR_HELPERS=(m|y)$' "$build/.config" || {
  echo "required: CONFIG_QCOM_PDR_HELPERS=m or y" >&2
  exit 1
}
# mkdir fails on an existing output, so neither source nor previous results
# can be overwritten. Keep the work tree for inspecting compiler failures.
mkdir "$output"
mkdir -p "$output/work/drivers/misc" "$output/work/drivers/soc/qcom"
cp "$src/drivers/misc/"{fastrpc.c,Kconfig} "$output/work/drivers/misc/"
cp "$src/drivers/soc/qcom/"{qcom_pd_mapper.c,pdr_internal.h} "$output/work/drivers/soc/qcom/"
cd "$output/work"
for p in \
  "$repo/pkgs/kernel/$1/patches/$rpc_patch" \
  "$repo/pkgs/kernel/patches/0001-soc-qcom-pd-mapper-add-sm8150-slpi-domains.patch"; do
  if patch --dry-run --batch --forward -p1 -F0 < "$p" >/dev/null 2>&1; then
    patch --batch --forward -p1 -F0 < "$p"
  elif patch --dry-run --batch --reverse -p1 -F0 < "$p" >/dev/null 2>&1; then
    echo "already applied: $p"
  else
    echo "source does not match patch: $p" >&2
    exit 1
  fi
done
printf 'obj-m += fastrpc.o\n' > drivers/misc/Makefile
printf 'obj-m += qcom_pd_mapper.o\n' > drivers/soc/qcom/Makefile
for dir in drivers/misc drivers/soc/qcom; do
  make -C "$build" ARCH=arm64 M="$PWD/$dir" -j"${NABU_BUILD_JOBS:-2}" modules
done
cp drivers/misc/fastrpc.ko drivers/soc/qcom/qcom_pd_mapper.ko "$output/"
cp "$build/include/config/kernel.release" "$output/kernel.release"
sha256sum "$build/.config" "$build/Module.symvers" \
  drivers/misc/fastrpc.c drivers/soc/qcom/qcom_pd_mapper.c \
  "$output/fastrpc.ko" "$output/qcom_pd_mapper.ko" > "$output/BUILD-SHA256SUMS"
echo "Modules built in $output; they have not been installed or loaded."
