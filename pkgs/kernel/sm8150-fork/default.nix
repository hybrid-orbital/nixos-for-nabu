{
  lib,
  stdenv,
  buildPackages,
  fetchFromGitLab,
  buildLinux,
  # device-specific fragment merged on top of the upstream sm8150 fragment
  extraFragment ? ./configs/extra-sm8150.config,
  requiredConfig ? ./configs/required-nabu.config,
  ...
}@args:

let
  # The reference (nabu_fedora) build deletes CONFIG_LOCALVERSION and passes
  # LOCALVERSION= / EXTRAVERSION=... to make; inside nixpkgs we keep the
  # plain release: the fork's arm64 defconfig leaves LOCALVERSION at its ""
  # default and the source tarball has no .git, so the kernel release is
  # "${modDirVersion}" with no suffix.
  modDirVersion = "6.17.0";
  version = "6.17.0-sm8150";

  src = fetchFromGitLab {
    domain = "gitlab.com";
    owner = "sm8150-mainline";
    repo = "linux";
    rev = "v${version}";
    hash = "sha256-K+cbu6aGdNxLiM2YimsEQLrL5YQvpPyOcUCvQ2M92Yk=";
  };

  /*
    Produce the final kernel .config with the exact semantics of the
    reference RPM build (kernel-sm8150.spec):

        make defconfig sm8150.config    # fork's arm64 defconfig + in-tree
                                        # upstream fragment (kconfig merge)
        sed -i '/^CONFIG_LOCALVERSION=/d' .config
        cat extra-sm8150.config >> .config
        make olddefconfig

    plus one fix: SPI_MT65XX disabled (see comment in `extraConfig` below).

    Kconfig tools must run on the BUILD machine — buildPackages.stdenv
    keeps this working for cross builds (x86_64 builder).
  */
  mergedConfig = buildPackages.stdenv.mkDerivation {
    pname = "nabu-kconfig-merge";
    inherit version src;

    nativeBuildInputs = with buildPackages; [
      flex
      bison
      bc
      perl
      openssl
      rsync
      python3Minimal
      pkg-config
      ncurses
    ];

    buildPhase = ''
      runHook preBuild

      echo ">>> defconfig + in-tree sm8150 fragment"
      make ARCH=arm64 defconfig sm8150.config

      echo ">>> drop CONFIG_LOCALVERSION (Kconfig empty default applies)"
      sed -i '/^CONFIG_LOCALVERSION=/d' .config

      echo ">>> extra fragment"
      sed 's/\r$//' ${extraFragment} >> .config

      echo ">>> platform fix"
      cat <<'FIX' >> .config
      # nabu is a Qualcomm SM8150 board: the nt36523 touchscreen driver has
      # MediaTek-only SPI code paths (guarded by CONFIG_SPI_MT65XX) that do
      # not compile against mainline SPI core headers, and the fork's
      # defconfig wrongly enables the MTK SPI controller driver.
      CONFIG_SPI_MT65XX=n
      FIX

      echo ">>> olddefconfig"
      make ARCH=arm64 olddefconfig

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp .config $out
      runHook postInstall
    '';
  };

  # Patch adding the merged config as a named defconfig, so nixpkgs'
  # buildLinux can consume it through its `defconfig` parameter.
  defconfigPatch = buildPackages.stdenv.mkDerivation {
    pname = "nabu-defconfig-patch";
    inherit version;

    buildCommand = ''
      target=arch/arm64/configs/nabu_defconfig
      {
        printf '%s\n' \
          "diff --git a/$target b/$target" \
          "new file mode 100644" \
          "--- /dev/null" \
          "+++ b/$target"
        # diff exits 1 when the files differ, which is the success case here
        diff -u /dev/null "${mergedConfig}" | tail -n +3 || true
      } > $out
    '';
  };
  kernel = buildLinux (args // {
    inherit version modDirVersion src;
    defconfig = "nabu_defconfig";

    # Keep the final config aligned with the Fedora RPM.  buildLinux defaults
    # to applying nixpkgs' common kernel config and answering every otherwise
    # optional Kconfig prompt with `m`; on this downstream arm64 tree that
    # enables thousands of unrelated drivers (DVB, MTD, other SoCs, ...),
    # substantially changes the reference config and makes a cross build take
    # hours.  The Fedora-derived defconfig already boots a systemd userspace;
    # the strict postConfigure check below covers nabu's boot invariants.
    enableCommonConfig = false;
    autoModules = false;

    kernelPatches = (args.kernelPatches or [ ]) ++ [
      {
        name = "nabu-fedora-runtime-fixes";
        patch = ./patches/0001-nabu-match-fedora-runtime-fixes.patch;
      }
      {
        # The generic board-2.bin carries no MAC: derive a stable address from
        # the SMBIOS board serial, with an ath10k_core.macaddr= override for
        # cases where the boot firmware exposes no usable serial.
        name = "nabu-ath10k-mac-address";
        patch = ./patches/0002-nabu-ath10k-mac-address.patch;
      }
      {
        # The WCN3990/SNOC firmware can send a fresh QMI FW_READY indication at
        # any time; ath10k runs that recovery check synchronously in the QMI
        # path and queues restart_work on the ordered workqueue, where later
        # triggers are coalesced and never complete ar->driver_recovery. The
        # resulting failure count can wedge the driver (ATH10K_STATE_WEDGED)
        # while the interface is down, and the next open then trips
        # WARN_ON(1) in ath10k_start() -- the "Wi-Fi hangs after idle" symptom.
        # Backport of upstream f35a07a4842a (fixes c256a94d1b1b), not in 6.17.y.
        name = "nabu-ath10k-recovery-check-workqueue";
        patch = ./patches/0004-nabu-ath10k-recovery-check-workqueue.patch;
      }
      {
        # adreno_system_suspend() returns -EBUSY when the GPU does not
        # quiesce within 1s, and the PM core treats that as fatal for the
        # whole system suspend -- in both s2idle and deep mode. On sm8150
        # the GMU suspend sequence is not reliable, so every suspend aborts.
        # Let the (already self-degrading) GMU shutdown run instead.
        name = "nabu-adreno-do-not-abort-system-suspend";
        patch = ./patches/0003-nabu-adreno-do-not-abort-system-suspend.patch;
      }
      {
        # Bluetooth UART (c8c000.serial / uart13) wake handling.
        #
        # During system sleep the PM core pins a runtime PM reference on every
        # device in the prepare phase (device_prepare ->
        # pm_runtime_get_noresume), so the pm_runtime_put_sync() that
        # uart_suspend_port() performs via uart_change_pm(UART_PM_STATE_OFF)
        # can never drive the usage count to zero. For a port that stays open
        # across system sleep -- which is exactly the case for the WCN3991
        # Bluetooth serdev -- qcom_geni_serial_runtime_suspend() is therefore
        # never invoked, geni_serial_resources_off() never runs and
        # pinctrl_pm_select_sleep_state() is skipped. The QUP13 pads then stay
        # in their "default" state (function qup13, bias-disable) rather than
        # switching to qup_uart13_sleep (GPIO input, RX pull-up), so the
        # floating/noisy RX pad plus the TLMM status latched while the
        # dedicated wake IRQ is masked make the armed GPIO46 wake IRQ fire
        # immediately and the system resumes from suspend-to-idle right away.
        #
        # Backport of upstream d0cd9c8d0fd5 ("serial: qcom-geni: add force
        # suspend/resume to system sleep callbacks") by Praveen Talari
        # <praveen.talari@oss.qualcomm.com>, merged via tty-next for v6.18-rc4
        # and not present in 6.17.y:
        #   https://git.kernel.org/torvalds/c/d0cd9c8d0fd5
        # The patch file keeps the upstream author, message and sign-off chain
        # and adds a backport note; the change itself is applied unmodified.
        # The BT controller, the wake IRQ and the wake capability all remain
        # functional; only the GENI SE power/pin state during system sleep changes.
        name = "qcom-geni-serial-force-suspend-system-sleep";
        patch = ./patches/0005-qcom-geni-serial-force-suspend-system-sleep.patch;
      }
      {
        # The MI_DRM_BLANK_UNBLANK notifier was sent in pre_enable(), before the
        # DSI host was enabled and before the panel had a chance to prepare/enable.
        # This caused the touchscreen driver to resume before the display was
        # ready, leading to intermittent screen failures on wake.
        # 
        # Move the notification to the enable() callback which runs after
        # panel_bridge_atomic_enable() calls drm_panel_enable(), ensuring the
        # display pipeline is fully up before notifying dependent drivers.
        name = "drm-msm-dsi-Move-MI_DRM_BLANK_UNBLANK-notification";
        patch = ./patches/0001-drm-msm-dsi-Move-MI_DRM_BLANK_UNBLANK-notification-t.patch;
      }
      {
        name = "nabu-defconfig";
        patch = defconfigPatch;
      }
    ];

    # The merged defconfig already disables SPI_MT65XX. LOCALVERSION_AUTO keeps
    # the release at "${modDirVersion}".
    # NR_CPUS: nixpkgs' common config forces 384; the device has 8 CPUs.
    #
    # Console: FRAMEBUFFER_CONSOLE defaults to DRM_FBDEV_EMULATION, neither of
    # which the sm8150 fragment or arm64 defconfig enable explicitly. Without a
    # boot text console the nabu panel never shows kernel logs (no
    # simple-framebuffer node in the DTB), so the device boots to a black
    # screen. Force the fbdev/KMS console stack on (`console=tty0` + fbcon).
    extraConfig = ''
      LOCALVERSION_AUTO n
      NR_CPUS 8
      # fbcon text console (arm64 defconfig leaves these unset -> n by default)
      SYSFB y
      FRAMEBUFFER_CONSOLE y
      FRAMEBUFFER_CONSOLE_ROTATION y
      DRM_FBDEV_EMULATION y
      # NixOS' default firewall uses these xtables matches, which the Fedora
      # fragment omits. Keep both IPv4 and IPv6 anti-spoofing rules functional.
      NETFILTER_XT_MATCH_PKTTYPE m
      IP_NF_MATCH_RPFILTER m
      IP6_NF_MATCH_RPFILTER m
      # Suspend/resume debugging (s2idle immediate-wake investigation).
      # PM_DEBUG enables the PM debug framework; PM_SLEEP_DEBUG follows
      # automatically (def_bool y once PM_DEBUG is on) and provides
      # /sys/power/{pm_test,pm_print_times,pm_wakeup_irq,pm_debug_messages}
      # plus the pm_debug_messages= cmdline parameter. PM_ADVANCED_DEBUG adds
      # the low-level per-device PM attributes in sysfs. PM_TRACE is x86-only
      # (PM_TRACE_RTC depends on X86) and is unavailable on arm64.
      PM_DEBUG y
      PM_ADVANCED_DEBUG y
      # Tracepoints for suspend/wakeup/irq events (power:suspend_resume,
      # power:wakeup_source_{activate,deactivate}, irq:irq_handler_{entry,exit}).
      # The arm64 defconfig disables FTRACE entirely; ENABLE_DEFAULT_TRACERS is
      # the lightweight events-only selector: it selects TRACING, which selects
      # TRACEPOINTS and EVENT_TRACING, while keeping the heavyweight function
      # tracers (FUNCTION_TRACER etc.) off. PM_SLEEP_DEBUG, TRACEPOINTS and
      # EVENT_TRACING are hidden symbols — their answers are not prompted but
      # double as build-time assertions: the strict unused-option check fails
      # the build if any link in the chain resolves to something other than y.
      FTRACE y
      ENABLE_DEFAULT_TRACERS y
      PM_SLEEP_DEBUG y
      TRACEPOINTS y
      EVENT_TRACING y
    '';

    # With nixpkgs' common config disabled, every remaining override is ours
    # and a missing/renamed Kconfig symbol is a real error.
    ignoreConfigErrors = false;

    extraMeta = {
      branch = "sm8150/6.17";
      description = "Mainline Linux kernel for SM8150 devices (Xiaomi Pad 5 / nabu)";
      maintainers = with lib.maintainers; [ ];
      platforms = [ "aarch64-linux" ];
    };
  });
in
kernel.overrideAttrs (previousAttrs: {
  # Independently verify the resolved config, including implied dependencies.
  postConfigure = (previousAttrs.postConfigure or "") + ''
    echo ">>> checking nabu boot-critical kernel configuration"
    while IFS= read -r requirement; do
      case "$requirement" in
        ""|'#'*) continue ;;
      esac
      if ! grep -Fqx "$requirement" "$buildRoot/.config"; then
        echo "ERROR: required nabu kernel setting is missing: $requirement" >&2
        exit 1
      fi
    done < ${requiredConfig}
  '';
})
