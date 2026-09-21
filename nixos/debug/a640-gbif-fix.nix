# Opt-in swap of a rebuilt msm.ko into the boot path (initrd + stage 2).
#
# The name is historical: the A640/A680 GBIF candidate now belongs to the kernel
# package (`pkgs/kernel/mainline-latest/patches/0009-...`, wired up in its
# default.nix), because a rebuild of drivers/gpu/drm/msm is not the module the
# kernel ships and a boot with it leaves the panel dark (measured;
# docs/kernel-gpu-fault.md, section 12.3).  A change that has to reach the
# device therefore goes into the kernel package, not here.
#
# What is left for this file is *observing* the driver over ssh: it installs the
# module built with `debug/vm-log-dmesg.sh`, i.e. the one carrying the
# `msm.vm_log_dmesg` parameter, so a capture can be read from the kernel log
# even though the screen stays dark.  Add
# `boot.kernelParams = [ "msm.vm_log_shift=8" ]` for the driver's own vm-log ring
# as well.
#
# `msm` is loaded from the initrd, so both the initrd's makeModulesClosure and
# stage-2 module aggregation have to see the replacement.  Do not combine this
# with another override of system.modulesTree.
{ config, pkgs, lib, ... }:
let
  kernel = config.boot.kernelPackages.kernel;

  module = pkgs.callPackage ../../pkgs/kernel/mainline-latest/msm-module.nix {
    inherit kernel;
    extraShell = builtins.readFile ../../pkgs/kernel/mainline-latest/debug/vm-log-dmesg.sh;
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
