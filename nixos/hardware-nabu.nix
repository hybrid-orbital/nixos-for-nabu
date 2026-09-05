# Xiaomi Pad 5 (nabu) hardware configuration.
#
# Reference: jhuang6451/nabu_fedora (nabu-fedora-configs-core), sm8150-mainline.
#
# Boot chain on the device: UEFI (Project Aloha / DBKP) -> rEFInd -> UKI in ESP.
# The kernel command line is baked into the UKI; rootfs is identified by
# PARTLABEL=linux (ext4), ESP by PARTLABEL=esp.
{
  config,
  pkgs,
  ...
}:

{
  # == Platform ==============================================================
  nixpkgs.hostPlatform = "aarch64-linux";
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;

  # == Kernel =================================================================
  boot.kernelPackages = pkgs.linuxKernel.packagesFor pkgs.kernel-sm8150;
  # No `quiet`: let kernel/systemd messages scroll on the console.
  boot.kernelParams = [
    "rw"
    "systemd.gpt_auto=no"
    "cryptomgr.notests"
    # Explicit text console: the nabu DTB has no simple-framebuffer node, so
    # the kernel must attach fbcon to tty0 to render early boot logs on the
    # panel (otherwise fbcon may not bind and the screen stays black).
    "console=tty0"
    "fbcon=rotate:1"
    "systemd.show_status=yes"
    "loglevel=7"
  ];

  # Boot splash: the nabu DTB has no simple-framebuffer node, so the panel
  # only comes up via the MSM DRM stack. The reference (nabu_fedora) ships
  # plymouth in the initrd (hostonly=no) to light the panel early. We keep
  # console=tty0 + loglevel=7 above so a failure still leaves text on screen.
  boot.plymouth.enable = true;

  # No bootloader managed from inside the system: the ESP is populated by
  # rEFInd + our UKI artifact (see packages.nabu-uki), built off-device.
  boot.loader.external = {
    enable = true;
    installHook = pkgs.writeShellScript "no-op-boot-install" ''
      echo "nabu: ESP/UKI is managed by the flake's nabu-uki output, nothing to do."
    '';
  };

  # Generic initramfs (not hostonly) with forced UFS drivers — the image is
  # built off-device and the rootfs lives on the UFS `linux` partition.
  # Mirrors the reference dracut config: hostonly=no + force_drivers ufs_qcom.
  boot.initrd.includeDefaultModules = true;
  boot.initrd.availableKernelModules = [
    "ufs_qcom"
    "ufshcd_pltfrm"
    "ufshcd_core"
    "ufshcd_pci"
    # Early display stack: no simple-framebuffer node, the panel is driven by
    # the MSM/KMS DRM driver, so it must be present in the initramfs for
    # plymouth/fbcon to light the screen before the rootfs is mounted.
    # DRM_MSM is builtin (=y), so only the panel/backlight are real modules;
    # ktz8866 is the actual backlight module name (not backlight_ktz8866).
    "panel_novatek_nt36523"
    "ktz8866"
  ];
  boot.initrd.kernelModules = [
    "ufs_qcom"
    "ufshcd_pltfrm"
  ];
  # MSM DRM is built into the kernel, so module-closure based firmware
  # discovery cannot see its runtime requests. Include the Adreno 640 blobs
  # explicitly so the display stack can initialize before mounting rootfs.
  boot.initrd.extraFirmwarePaths = [
    "qcom/a630_sqe.fw"
    "qcom/a640_gmu.bin"
    "qcom/sm8150/xiaomi/nabu/a640_zap.mbn"
  ];

  # == Filesystems ============================================================
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/linux";
    fsType = "ext4";
    options = [
      "rw"
      "errors=remount-ro"
      "x-systemd.growfs"
    ];
  };

  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-partlabel/esp";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # == Firmware ===============================================================
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ pkgs.xiaomi-nabu-firmware ];

  # == Qualcomm remoteproc services ==========================================
  # Match Fedora's nabu preset: Linux 6.17 provides the QRTR name service and
  # PD mapper in-kernel, while userspace only runs rmtfs and tqftpserv.
  systemd.services.rmtfs = {
    description = "Qualcomm remotefs service";
    before = [ "NetworkManager.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/dev/qcom_rmtfs_mem1";
    serviceConfig = {
      ExecStart = "${pkgs.rmtfs}/bin/rmtfs -r -P -s";
      Restart = "always";
      RestartSec = "1";
    };
  };

  systemd.services.tqftpserv = {
    description = "QRTR TFTP service";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.tqftpserv}/bin/tqftpserv";
      Restart = "always";
    };
  };

  # == Audio (quad speakers, CS35L41 amplifiers) ==============================
  environment.etc."alsa-ucm2/conf.d/sm8150/sm8150.conf".source =
    "${pkgs.nabu-alsa-ucm}/sm8150.conf";
  environment.etc."alsa-ucm2/Xiaomi/nabu/HiFi.conf".source =
    "${pkgs.nabu-alsa-ucm}/HiFi.conf";

  # == Quirks =================================================================
  # Force /dev/rtc symlink to rtc1 (pm8150 RTC keeps time when powered off)
  services.udev.extraRules = ''
    SUBSYSTEM=="rtc", KERNEL=="rtc1", SYMLINK+="rtc", OPTIONS+="link_priority=10"
  '';

  # ath10k_snoc hangs the platform on warm reboot if not unloaded first
  systemd.services.ath10k-shutdown = {
    description = "Nabu - Disable WiFi Modules on Shutdown";
    after = [
      "network-online.target"
      "graphical.target"
    ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = "${pkgs.kmod}/bin/rmmod ath10k_snoc ath10k_core";
    };
  };

  # == Networking =============================================================
  networking.networkmanager = {
    enable = true;
    wifi.backend = "iwd";
  };
  networking.wireless.enable = false; # avoid wpa_supplicant conflict

  # == Zram (matches reference: full-RAM size, zstd) ==========================
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # == Power ==================================================================
  powerManagement.enable = true;
}
