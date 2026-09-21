# Take the kernel's own `modules` output and swap in a debug build of msm.ko.
#
# Feed this output into `system.modulesTree` to run a replacement GPU driver
# without rebuilding the kernel (see nixos/debug/a640-gbif-fix.nix). `msm` is
# loaded from the initrd, so both initrd and stage-2 module aggregation must
# consume this output. `system.replaceDependencies` skips the initrd by default
# and does not replace module bytes inside its compressed archive.
#
# The directory name is taken from the kernel derivation instead of being
# hard-coded, and both sides are checked, so a mismatch (wrong kernel selected,
# module not built) fails with a readable message instead of the shell's
# "No such file or directory" on a redirection.
{
  lib,
  runCommand,
  xz,
  # The kernel package the system runs (`config.boot.kernelPackages.kernel`).
  kernel,
  # A derivation whose $out holds msm.ko, i.e. `nabu-msm-module[-debug]`.
  module,
}:

let
  rel = "lib/modules/${kernel.modDirVersion}/kernel/drivers/gpu/drm/msm/msm.ko.xz";
in
runCommand "linux-${kernel.modDirVersion}-modules-debug-msm" { } ''
  set -euo pipefail

  test -e ${module}/msm.ko || {
    echo "error: ${module}/msm.ko does not exist (did the module build run?)" >&2
    ls -l ${module} >&2 || true
    exit 1
  }

  cp -r ${kernel.modules} $out
  chmod -R u+w $out

  test -e "$out/${rel}" || {
    echo "error: $out/${rel} does not exist - is this the kernel modules output" >&2
    echo "       of ${kernel.modules} (modDirVersion ${kernel.modDirVersion})?" >&2
    ls "$out/lib/modules" >&2
    exit 1
  }

  ${xz}/bin/xz -c ${module}/msm.ko > "$out/${rel}"

  echo ">>> replaced $out/${rel}"
  ${xz}/bin/xz -dc "$out/${rel}" \
    | grep -m1 '^vermagic=' \
    || echo ">>> (no vermagic found, check the module)"
''
