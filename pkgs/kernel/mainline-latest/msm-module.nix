# Build only part of the mainline-latest kernel tree - by default the GPU
# driver - against the kbuild tree of the already built kernel.
#
# Why: `nix build .#nabu-kernel-mainline-latest` costs tens of minutes, while
# the interesting work (msm GPU/VM_BIND, panel, DSI PHY) lives in a handful of
# directories.  This derivation reuses `${kernel.dev}`, which carries the
# resolved `.config`, `Module.symvers` and the generated headers, and compiles
# just those directories:
#
#   nix build .#nabu-msm-module && ls result
#   # or, for the panel driver as well:
#   nix build --impure --expr '(builtins.getFlake (toString ./.))
#     .packages.aarch64-linux.nabu-msm-module.override { dirs = [ ... ]; }'
#
# The kernel is built without CONFIG_MODVERSIONS and without CONFIG_MODULE_SIG
# (both checked in the built `.config`), so the resulting .ko loads on the
# running kernel as long as vermagic matches, which it does by construction.
# Iterating on a patch is then: edit patch -> nix build .#nabu-msm-module ->
# copy msm.ko to the device instead of rebuilding the whole kernel.
{
  lib,
  stdenv,
  kernel,
  # Subdirectories of the kernel source that are compiled as modules.
  dirs ? [ "drivers/gpu/drm/msm" ],
  # Additional patches, applied after the ones the kernel package carries.
  extraPatches ? [ ],
  # Shell snippet run inside the source tree after all patches, for debug-only
  # instrumentation that is easier to express as an edit than as a patch (see
  # ./debug/vm-log-dmesg.sh).
  extraShell ? "",
  python3,
  ...
}@args:

let
  kernelBuildDir = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";

  # The kernel package patches are the authoritative source of what the running
  # kernel was built with, so reuse the very same files.
  kernelPatchDir = ./patches;
in
stdenv.mkDerivation {
  pname = "nabu-drm-module";
  version = kernel.version;

  src = kernel.src;

  # `python3` is for the debug snippets passed via `extraShell`.
  nativeBuildInputs = (kernel.nativeBuildInputs or [ ]) ++ [ python3 ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # Absolute path of the (unpacked) source tree; kbuild and the tracepoint
    # headers need to refer to it by name.  `unpackPhase` leaves us in it.
    modsrc=$PWD
    echo ">>> module source tree: $modsrc"

    # Apply the same patch series the kernel package applies, so the module is
    # built from the same sources the running kernel was built from.  The
    # tarball is already unpacked into $sourceRoot by unpackPhase.
    for p in ${kernelPatchDir}/*.patch ${lib.concatMapStringsSep " " (p: "${p}") extraPatches}; do
      echo ">>> applying $(basename "$p")"
      if ! patch -p1 -F0 -l --forward < "$p"; then
        echo ">>> patch failed; file under drivers/gpu/drm/msm around the hunk:"
        sed -n '15,30p' drivers/gpu/drm/msm/msm_gem_vma.c | cat -A | head -20
        exit 1
      fi
    done

    ${extraShell}

    for dir in ${lib.concatMapStringsSep " " (d: "'${d}'") dirs}; do
      echo ">>> building $dir"
      # The tracepoint headers do `#define TRACE_INCLUDE_PATH
      # ../../drivers/gpu/drm/msm` and include it from <trace/define_trace.h>,
      # which resolves that path against the *kernel* source tree - in an `M=`
      # build that is the kernel package's `dev` output, which ships headers
      # only.  Adding this tree's include/trace to the search path makes the
      # relative path resolve into this tree instead.
      make -C ${kernelBuildDir} \
        ARCH=arm64 \
        M=$modsrc/$dir \
        KCFLAGS="-I$modsrc/include/trace" \
        -j"''${NIX_BUILD_CORES:-1}" \
        modules
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    find . -name '*.ko' -exec cp -v {} $out/ \;
    for ko in $out/*.ko; do
      echo ">>> $(basename "$ko"): $(modinfo -F vermagic "$ko" 2>/dev/null || echo 'vermagi unavailable')"
    done
    runHook postInstall
  '';

  meta = {
    description = "GPU/DRM modules of the nabu mainline-latest kernel, built alone";
    inherit (kernel.meta) platforms;
  };
}
