# Opt-in A/B test of the A640 GBIF initialization fix. Rebuild the initrd
# with the replacement module; msm is already in use after early boot.
# See docs/kernel-gpu-fault.md, section 12. Do not combine this with another
# override of system.modulesTree or with the full-kernel form of the patch.
{ config, pkgs, lib, ... }:
let
  kernel = config.boot.kernelPackages.kernel;
  module = pkgs.callPackage ../../pkgs/kernel/mainline-latest/msm-module.nix {
    inherit kernel;
    extraPatches = [
      ../../pkgs/kernel/mainline-latest/experimental/0001-drm-msm-a6xx-restore-a640-gbif.patch
    ];
  };
  replacement = pkgs.callPackage ../../pkgs/kernel/mainline-latest/msm-modules-debug.nix {
    inherit kernel module;
  };
in
{
  assertions = [
    {
      assertion = config.nabu.kernel.name == "mainline-latest";
      message = "a640-gbif-fix.nix requires nabu.kernel.name = mainline-latest";
    }
  ];

  # Feed the replacement into normal module aggregation / depmod and the
  # initrd's makeModulesClosure. replaceDependencies skips the initrd by
  # default and cannot replace the module bytes inside its compressed cpio.
  system.modulesTree = lib.mkForce ([ replacement ] ++ config.boot.extraModulePackages);
}
