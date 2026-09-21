# Debug-only module: arm the GPU fault tracing before the Wayland session
# starts.
#
# Why: on this device the first `*** gpu fault: ttbr0=...` of a boot happens
# while the shell (noctalia) comes up, i.e. around 90 s in, and the VM that
# faults was created before that.  A manually started capture therefore sees
# neither the trace history of that fault nor its page table
# (`msm_iommu_pagetable_params` -> ttbr0 mapping).  Starting the capture as a
# system service fixes both.
#
# Usage: import this file temporarily
#
#   imports = [ ./debug/ccu-capture.nix ];      # in nixos/configuration.nix
#
# (plus, to also get the driver's own vm-log ring, which only exists for VMs
# created after the parameter takes effect:
#
#   boot.kernelParams = [ "msm.vm_log_shift=8" ];
#
# ) then reboot, reproduce, and read
#
#   /var/lib/nabu-ccu/nabu-ccu-*/SUMMARY.txt
#
# Remove the import afterwards.
{ config, pkgs, lib, ... }:

{
  systemd.services.nabu-ccu-capture = {
    description = "capture the first GPU fault of this boot";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-modules-load.service"
      "systemd-udev-settle.service"
    ];
    before = [ "graphical.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "no";
      StateDirectory = "nabu-ccu";
      # The script stops by itself after the first fault plus a grace period;
      # --no-package keeps everything as plain files under the state directory.
      ExecStart = "${pkgs.bash}/bin/bash ${
        ../../scripts/nabu-ccu-fault-capture.sh
      } --out /var/lib/nabu-ccu --timeout 1200 --grace 120 --no-package";
    };
  };
}
