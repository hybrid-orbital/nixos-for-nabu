# Opt-in A/B test of the A640 GBIF initialization fix. Rebuild the initrd
# with the replacement module; msm is already in use after early boot.
# See docs/kernel-gpu-fault.md, section 12. Do not combine this with another
# override of system.modulesTree or with the full-kernel form of the patch.
#
# Run this as a pair of boots.  `msm-module.nix` compiles drivers/gpu/drm/msm
# with `make M=... modules`, which is not the build the kernel's own msm.ko went
# through (docs/kernel-gpu-fault.md, section 12.3), so a single boot cannot tell
# the patch apart from the rebuild: boot once with variant = "baseline" (the
# unmodified rebuild) and once with "gbif-fix".  If the baseline boot shows the
# same problem, nothing about the patch has been learned yet.
{ config, pkgs, lib, ... }:
let
  kernel = config.boot.kernelPackages.kernel;
  variant = config.nabu.debug.msmSwap.variant;

  module = pkgs.callPackage ../../pkgs/kernel/mainline-latest/msm-module.nix {
    inherit kernel;
    extraPatches = lib.optionals (variant == "gbif-fix") [
      ../../pkgs/kernel/mainline-latest/experimental/0001-drm-msm-a6xx-restore-a640-gbif.patch
    ];
  };

  replacement = pkgs.callPackage ../../pkgs/kernel/mainline-latest/msm-modules-debug.nix {
    inherit kernel module;
  };
in
{
  options.nabu.debug.msmSwap.variant = lib.mkOption {
    type = lib.types.enum [
      "baseline"
      "gbif-fix"
    ];
    default = "gbif-fix";
    description = ''
      Which module to put into the boot path: the unmodified rebuild (the
      control) or the rebuild with the A640/A680 GBIF candidate patch.  Both
      are built the same way, so booting both is what separates an effect of
      the patch from an effect of rebuilding the module at all.
    '';
  };

  config = {
    assertions = [
      {
        assertion = config.nabu.kernel.name == "mainline-latest";
        message = "a640-gbif-fix.nix requires nabu.kernel.name = mainline-latest";
      }
    ];

    # Feed the replacement into normal module aggregation / depmod and the
    # initrd's makeModulesClosure. replaceDependencies skips the initrd by
    # default and cannot replace the module bytes inside its compressed cpio.
    system.modulesTree = lib.mkForce (
      [ replacement ] ++ config.boot.extraModulePackages
    );
  };
}
