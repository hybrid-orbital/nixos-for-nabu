# Boot via systemd-boot: no UKI, no rEFInd.
#
# The Project Aloha UEFI firmware boots the removable-media fallback path
# /EFI/BOOT/BOOTAA64.EFI and has no usable NVRAM boot variables, so we set
# boot.loader.efi.canTouchEfiVariables = false: bootctl then installs
# systemd-boot to that fallback path (plus /EFI/systemd/).
#
# The device tree is installed to the ESP and handed to the EFI-stub kernel by
# systemd-boot through the Boot Loader Spec `devicetree` keyword — nixpkgs
# wires this up natively via boot.loader.systemd-boot.installDeviceTree, so no
# `dtb=` kernel parameter and no UKI are needed.
{
  pkgs,
  ...
}:

let
  # Reuse the fixed source shipped with the original nabu rEFInd setup.
  dualboot = pkgs.fetchFromGitHub {
    owner = "hybrid-orbital";
    repo = "nabu_fedora_packages";
    rev = "cee0eec4d4f8681bf6fe423ff51904a649340ecd";
    sha256 = "0llfds8a1dfn9qldg6gf4kp50mnpb619vwf91bw08cqsabnsyhm3";
  };
  efiFiles = "${dualboot}/nabu-fedora-dualboot-efi/boot/efi/EFI";
in
{
  # Build the nabu device tree so systemd-boot can install it to the ESP.
  hardware.deviceTree = {
    enable = true;
    # Path relative to ${kernel}/dtbs.  arm64 `make dtbs_install` keeps the
    # vendor subdirectory, so the full path is
    # ${kernel}/dtbs/qcom/sm8150-xiaomi-nabu.dtb.
    name = "qcom/sm8150-xiaomi-nabu.dtb";
  };

  boot.loader.systemd-boot = {
    enable = true;
    # Defaults to `hardware.deviceTree.enable && name != null`; kept explicit.
    installDeviceTree = true;

    # systemd-boot loads drivers with the aa64.efi suffix before its menu.
    # extraFiles also deploys these files on nixos-rebuild boot/switch.
    extraFiles = {
      "EFI/systemd/drivers/GopRotate_aa64.efi" = "${efiFiles}/BOOT/drivers_aa64/GopRotate_aa64.efi";
      "EFI/Android/Reboot2Android.efi" = "${efiFiles}/Android/Reboot2Android.efi";
    };

    # Android dualboot entry (Project Aloha's Reboot2Android stub).
    extraEntries."android.conf" = ''
      title Android
      efi /EFI/Android/Reboot2Android.efi
      sort-key o_android
    '';
  };

  boot.loader.efi = {
    # NixOS mounts the ESP at /boot/efi (see hardware-nabu.nix).
    efiSysMountPoint = "/boot/efi";
    # Project Aloha has no usable NVRAM boot variables; rely on the removable
    # fallback /EFI/BOOT/BOOTAA64.EFI instead.
    canTouchEfiVariables = false;
  };

  # Short boot-menu timeout before the default (NixOS) entry boots.
  boot.loader.timeout = 5;

  # == Boot diagnostics =======================================================
  # Use this option instead of a second loglevel= argument: NixOS otherwise
  # appends its default loglevel=4 after manually supplied kernel parameters.
  # Keep debug messages in the kernel ring buffer without flooding fbcon.
  # Aggressive console tracing coincided with intermittent grey-screen boots.
  boot.consoleLogLevel = 7;
  boot.plymouth.enable = false;
  boot.initrd.verbose = true;

  boot.kernelParams = [
    # EFI stub output uses the firmware console before Linux takes over.
    "efi=debug"
    # Retain early messages until the display and journald are ready.
    "printk.time=1"
    "log_buf_len=4M"
    # Keep the normal fbcon takeover policy; do not force an early bind.
    "consoleblank=0"
    # These apply to both initrd and the main system, including early PID 1.
    "systemd.show_status=yes"
    "systemd.log_level=info"
  ];

  # Preserve logs from previous boots, with bounded disk and runtime use.
  services.journald = {
    settings.Journal = {
      storage = "persistent";
      SystemMaxUse = "56M";
      RuntimeMaxUse = "64M";
      SyncIntervalSec = "30s";
    };
  };
}
