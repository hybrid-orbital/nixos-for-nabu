# Xiaomi Pad 5 (nabu) hardware configuration.
#
# Reference: jhuang6451/nabu_fedora (nabu-fedora-configs-core), sm8150-mainline.
#
# Boot chain on the device: UEFI (Project Aloha / DBKP) -> systemd-boot in ESP.
# systemd-boot loads the EFI-stub kernel + initrd + DTB straight from the ESP
# (no UKI); Linux storage is identified by PARTLABEL=linux, ESP by
# PARTLABEL=esp.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.nabu.kernel.name = lib.mkOption {
    type = lib.types.enum (builtins.attrNames pkgs.kernels);
    default = "sm8150-fork";
    description = ''
      Kernel to build the device with.  See pkgs/kernel/default.nix for the
      available names: `sm8150-fork` is the pinned sm8150-mainline fork,
      `mainline-latest` is nixpkgs' linux_latest plus the downstream nabu
      patches (the kernel under test for the next kernel version).
    '';
  };

  config = {
  # == Platform ==============================================================
  nixpkgs.hostPlatform = "aarch64-linux";
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;

  # == Kernel =================================================================
  # Select with `nabu.kernel.name`; both kernels build the same device tree
  # (qcom/sm8150-xiaomi-nabu.dtb, see nixos/boot.nix).
  boot.kernelPackages = pkgs.linuxKernel.packagesFor pkgs.kernels.${config.nabu.kernel.name};
  # Root mounts are generated from the selected storage profile.
  boot.kernelParams = [
    "rw"
    "systemd.gpt_auto=no"
    "cryptomgr.notests"
    # Default to suspend-to-idle. Device suspend callbacks run identically in
    # s2idle and deep mode, so the GPU quiesce abort is fixed by the adreno
    # kernel patch (0003), not by this parameter; this only selects the
    # lighter, firmware-independent sleep mode. Deep suspend via PSCI stays
    # available for per-device testing through /sys/power/mem_sleep.
    "mem_sleep_default=s2idle"
    # Explicit text console: the nabu DTB has no simple-framebuffer node, so
    # the kernel must attach fbcon to tty0 to render early boot logs on the
    # panel (otherwise fbcon may not bind and the screen stays black).
    "console=tty0"
    # fbcon uses clockwise quarter-turns; niri's counter-clockwise 270
    # gives the same landscape orientation. This only affects Linux TTYs.
    "fbcon=rotate:1"
  ];

  # The ESP is managed by systemd-boot (see boot.nix): nixos-rebuild boot|switch
  # runs bootctl install + the systemd-boot builder, which deploys the kernel,
  # initrd, DTB and loader entries under /boot/efi.  Nothing to do here.

  # Generic initramfs (not hostonly) with forced UFS drivers — the image is
  # built off-device and the rootfs lives on the UFS `linux` partition.
  # Mirrors the reference dracut config: hostonly=no + force_drivers ufs_qcom.
  # NixOS' default set is PC-oriented (AHCI/PATA/NVMe and assorted USB HID).
  # The Fedora-aligned nabu kernel intentionally does not provide several of
  # those drivers, and the root device is UFS.  Keep this initrd generic for
  # nabu hardware through the explicit list below, not generic for PCs.
  boot.initrd.includeDefaultModules = false;
  # Qualcomm's secure environment is not exposed as a PC-style TPM.  The
  # systemd package enables TPM units by default and would otherwise inject
  # tpm-tis/tpm-crb into the initrd, neither of which exists in this kernel.
  boot.initrd.systemd.tpm2.enable = false;
  systemd.tpm2.enable = false;
  boot.initrd.availableKernelModules = [
    "ufs_qcom"
    "ufshcd_pltfrm"
    "ufshcd_core"
    # UFS PHY.  The pinned 6.17 fork kernel builds the QMP UFS PHY in
    # (CONFIG_PHY_QCOM_QMP_UFS=y); `mainline-latest` has it as a module, and
    # because the PHY is matched through the device tree it is *not* a symbol
    # dependency of ufs_qcom, so it is not pulled in automatically: without it
    # ufs_qcom_init() returns -EPROBE_DEFER forever and the root filesystem
    # never appears.
    "phy_qcom_qmp_ufs"
    # Early display stack: no simple-framebuffer node, the panel is driven by
    # the MSM/KMS DRM driver, so it must be present in the initramfs for
    # fbcon to light the screen before the rootfs is mounted.
    "drm"
    "drm_kms_helper"
    "msm"
    "panel_novatek_nt36523"
    "ktz8866"
    # The DSI host requests the REFGEN regulator (see the refgen-supply links
    # in the nabu device tree).  It is a module in `mainline-latest` and
    # built-in in the fork kernel; without it here the DSI host defers and the
    # panel never comes up, which leaves the whole boot without a console.
    "qcom_refgen_regulator"
    # USB-C: the USB core, HID and storage drivers are built in, but the combo
    # PHY and the Type-C class driver are modules.  Keeping them in the
    # initramfs means an attached keyboard still works if the boot fails before
    # the root filesystem is mounted, which is the only interactive way to
    # inspect such a failure on this device (there is no serial console).
    "phy_qcom_qmp_combo"
    "typec"
  ];
  boot.initrd.kernelModules = [
    # Keep display drivers available above, but let udev load them on demand.
    # Force only the storage drivers needed to mount the root filesystem.
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
  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-partlabel/esp";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # == Firmware ===============================================================
  # The stock linux-firmware package is 791 MiB compressed (1.8 GiB raw) and
  # brings the whole firmware environment to ~827 MiB of the system closure,
  # almost all of which is unusable here (x86 GPU/CPU-microcode/audio firmware,
  # Intel and Atheros PCIe WiFi, datacenter NICs, other Qualcomm SoCs).
  # linux-firmware-nabu keeps the onboard + common USB-device parts (88 MiB
  # compressed; the firmware environment becomes 100 MiB); see
  # pkgs/linux-firmware-nabu.nix for the keep list and the reasoning.
  #
  # Turning enableRedistributableFirmware off also disables
  # wirelessRegulatoryDatabase by default, so it has to be enabled explicitly —
  # otherwise WiFi loses regulatory.db.
  hardware.enableRedistributableFirmware = false;
  hardware.wirelessRegulatoryDatabase = true;
  hardware.firmware = [
    pkgs.linux-firmware-nabu
    pkgs.xiaomi-nabu-firmware
  ];

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
  # The four CS35L41 amps hang off the QUAT_TDM_RX_0 backend.  Bringing them
  # up needs the Q6AFE frontend→backend route plus the per-amp soft-ramp and
  # volume csets; both live in the ALSA UCM profile (pkgs/alsa-ucm, packaged
  # as pkgs.nabu-alsa-ucm), which WirePlumber/ACP consumes to build the card's
  # profiles and ports.  (This replaces the old workaround: a boot-time amixer
  # service plus a WirePlumber rule that bypassed UCM and forced hw:0,0.)
  #
  # ALSA looks the profile up as ucm2/conf.d/<CardDriver>/<CardDriver>.conf,
  # where CardDriver is the kernel's card->driver_name ("sm8150"); the
  # platform driver / module names ("snd-sm8150", "snd_soc_sm8150") are never
  # queried.  nixpkgs' alsa-lib resolves ucm2 through a symlink inside its own
  # store path (<alsa-lib>/share/alsa/ucm2 -> alsa-ucm-conf), so our profile
  # is only visible when ALSA_CONFIG_UCM2 points at pkgs.alsa-ucm-conf-nabu —
  # the stock alsa-ucm-conf tree merged with the nabu profile, because the
  # variable *replaces* the whole search directory (alsa-lib src/ucm/utils.c).
  # Session variables reach user services through PAM; the per-service copies
  # are belt-and-braces for the processes that probe UCM.  ALSA use outside
  # PipeWire (e.g. a raw aplay) needs `alsaucm -c hw:0 set _verb HiFi` first.
  environment.sessionVariables.ALSA_CONFIG_UCM2 =
    "${pkgs.alsa-ucm-conf-nabu}/share/alsa/ucm2";
  systemd.user.services.pipewire.environment.ALSA_CONFIG_UCM2 =
    "${pkgs.alsa-ucm-conf-nabu}/share/alsa/ucm2";
  systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 =
    "${pkgs.alsa-ucm-conf-nabu}/share/alsa/ucm2";

  # == Quirks =================================================================
  # Force /dev/rtc symlink to rtc1 (pm8150 RTC keeps time when powered off)
  services.udev.extraRules = ''
    SUBSYSTEM=="rtc", KERNEL=="rtc1", SYMLINK+="rtc", OPTIONS+="link_priority=10"
  '';

  # ath10k_snoc hangs the platform on warm reboot if not unloaded first
  systemd.services.ath10k-shutdown = {
    description = "Nabu - Disable WiFi Modules on Shutdown";
    # Only order shutdown; arming this hook does not require connectivity.
    # Stop ordering is reversed, so unload before the network stack stops.
    after = [
      "network.target"
      "graphical.target"
    ];
    wantedBy = [ "default.target" ];
    # A configuration switch must not run ExecStop and disconnect Wi-Fi.
    restartIfChanged = false;
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

  # The generic board-2.bin carries no MAC, so the kernel patch
  # (pkgs/kernel/sm8150-fork/patches/0002-nabu-ath10k-mac-address.patch) derives a stable
  # locally-administered address from the SMBIOS board serial. If the boot
  # firmware exposes no usable serial (or a fixed MAC is required, e.g. for a
  # DHCP reservation), override it here with the per-device address:
  #
  #   boot.extraModprobeConfig = ''
  #     options ath10k_core macaddr=00:11:22:33:44:55
  #   '';

  # == Zram (matches reference: full-RAM size, zstd) ==========================
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # == Power ==================================================================
  powerManagement.enable = true;
  };
}
