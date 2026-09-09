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
  # Root mounts are generated from the selected storage profile.
  boot.kernelParams = [
    "rw"
    "systemd.gpt_auto=no"
    "cryptomgr.notests"
    # The Adreno 640 (MSM DRM) suspend path is incomplete on sm8150-mainline,
    # so deep suspend aborts. Force suspend-to-idle, which freezes userspace
    # and idles the CPUs without triggering the broken GPU power collapse.
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
    # Early display stack: no simple-framebuffer node, the panel is driven by
    # the MSM/KMS DRM driver, so it must be present in the initramfs for
    # fbcon to light the screen before the rootfs is mounted.
    "drm"
    "drm_kms_helper"
    "msm"
    "panel_novatek_nt36523"
    "ktz8866"
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
  # WORKAROUND: WirePlumber/ACP has no working UCM for this card yet, so we
  # bypass UCM entirely:
  #   - nabu-speaker-route arms the CS35L41 TDM route directly at boot (the
  #     QUAT_TDM_RX_0 mixer + the four soft-ramp/volume controls) — the job
  #     the UCM EnableSequence would normally do.
  #   - a WirePlumber rule sets api.alsa.use-ucm=false and api.alsa.pcm=hw:0,0
  #     so PipeWire exposes the card as a plain stereo sink.
  # (Same approach as Mooling0602's nabu-nixos-kde-config.)
  #
  # The proper fix is to load the UCM profile (pkgs.nabu-alsa-ucm, kept as a
  # fallback in pkgs/default.nix) through alsa-ucm-conf; revisit once
  # WirePlumber/ACP can consume this card's UCM.
  systemd.services.nabu-speaker-route = {
    description = "Enable nabu speaker route (CS35L41)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udevd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nabu-speaker-route" ''
        AMIXER=${pkgs.alsa-utils}/bin/amixer
        i=0
        while [ $i -lt 25 ]; do
          $AMIXER -c0 cget "name='QUAT_TDM_RX_0 Audio Mixer MultiMedia1'" >/dev/null 2>&1 && break
          sleep 1
          i=$((i+1))
        done
        $AMIXER -c0 cset "name='QUAT_TDM_RX_0 Audio Mixer MultiMedia1'" 1
        for a in BR TR BL TL; do
          $AMIXER -c0 cset "name='$a PCM Soft Ramp'" 4ms
          $AMIXER -c0 cset "name='$a Analog PCM Volume'" 5
        done
      '';
    };
  };

  # Expose the X5 card to PipeWire as a plain hw:0,0 sink (no UCM profile).
  environment.etc."xdg/wireplumber/wireplumber.conf.d/51-nabu-speaker.conf".text = ''
    monitor.alsa.rules = [
      {
        matches = [
          { device.name = "alsa_card.platform-sound" }
        ]
        actions = {
          update-props = {
            api.alsa.pcm = "hw:0,0"
            api.alsa.use-ucm = false
            node.name = "nabu-speakers"
            node.description = "内置扬声器 (CS35L41)"
            audio.format = "S16LE"
            audio.rate = 48000
            audio.channels = 2
            audio.position = [ FL FR ]
          }
        }
      }
    ]
  '';

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
  # (pkgs/kernel/patches/0002-nabu-ath10k-mac-address.patch) derives a stable
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
}
