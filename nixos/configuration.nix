# Base NixOS configuration for Xiaomi Pad 5 (nabu).
# The current image imports niri + Noctalia; standalone variants are planned.
{
  pkgs,
  lib,
  ...
}:

let
  # Upstream alsa-utils enables the audio loopback tester (alsabat) and a
  # PipeWire plugin directory by default.  For a recovery/bring-up image that
  # pulls FFTW (and therefore a complete target gfortran compiler) plus much of
  # the desktop audio stack into an otherwise minimal cross build.  Keep the
  # normal mixer/playback/UCM tools, but omit those optional test/plugin bits.
  alsaUtilsMinimal = (pkgs.alsa-utils.override { withPipewireLib = false; }).overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-bat" ];
    buildInputs = lib.remove pkgs.fftwFloat (old.buildInputs or [ ]);
    # The upstream postFixup also wraps every utility with alsa-plugins.  That
    # plugin bundle brings an entire desktop multimedia closure (PulseAudio,
    # JACK, FFmpeg/GStreamer and another FFTW) into this console image.  Direct
    # ALSA hardware access and UCM only need alsa-lib; a later desktop/PipeWire
    # configuration will supply its own plugin path.
    postFixup = ''
      mv $out/bin/alsa-info.sh $out/bin/alsa-info
      wrapProgram $out/bin/alsa-info \
        --prefix PATH : "${
          lib.makeBinPath [
            pkgs.which
            pkgs.pciutils
            pkgs.procps
            pkgs.tree
          ]
        }" \
        --prefix PATH : $out/bin
    '';
  });

  # nabu is Wi-Fi-only.  The stock NetworkManager derivation nevertheless
  # enables ModemManager and carries BlueZ even though its BlueZ DUN feature is
  # disabled.  While cross-compiling it also builds a second native
  # NetworkManager merely to copy documentation into the target outputs; that
  # currently trips a nixpkgs dbus-python cross-package bug.  Keep the actual
  # NetworkManager/iwd Wi-Fi path while dropping these unused inputs.
  networkManagerNabu = pkgs.networkmanager.overrideAttrs (old: {
    mesonFlags = map (
      flag: if lib.hasPrefix "-Dmodem_manager=" flag then "-Dmodem_manager=false" else flag
    ) (old.mesonFlags or [ ]);
    buildInputs = lib.subtractLists [
      pkgs.bluez5
      pkgs.modemmanager
    ] (old.buildInputs or [ ]);
    postFixup = ''
      mkdir -p "$man" "$devdoc"
      # In the cross build this generator keeps a raw #!/bin/bash (patchShebangs
      # skips it); in native builds patchShebangs has already rewritten it to
      # the store bash.  Replace the shebang non-fatally, but require the tool
      # paths below (generators run before the normal service environment).
      substituteInPlace "$out/lib/systemd/system-generators/nm-initrd-generator.sh" \
        --replace '#!/bin/bash' '#!${pkgs.bash}/bin/bash' \
        --replace-fail 'ln -s ' '${pkgs.coreutils}/bin/ln -s ' \
        --replace-fail 'mkdir -p ' '${pkgs.coreutils}/bin/mkdir -p ' \
        --replace-fail '/usr/lib/systemd/system/' "$out/lib/systemd/system/"
    '';
  });
in
{
  imports = [
    ./hardware-nabu.nix
    ./boot.nix
    ./niri.nix
    ./storage
    ./images
  ];

  # == Identity ===============================================================
  networking.hostName = "nabu";
  system.stateVersion = "25.11";

  # == Users ==================================================================
  users.users.nabu = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      # TouchpadEmulator reads /dev/input/* and writes /dev/uinput
      "input"
    ];
    initialPassword = lib.mkDefault "nabu";
  };

  # Noctalia greeter handles graphical login; TTY autologin remains enabled.
  services.getty.autologinUser = "nabu";

  # == Nix ====================================================================
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs.config.allowUnfree = true;

  # This is a bring-up image, and cross-building the NixOS manuals pulls in a
  # browser and a large documentation toolchain that is irrelevant at boot.
  documentation.enable = false;
  documentation.nixos.enable = false;

  # == Locale =================================================================
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_CN.UTF-8";
    LC_IDENTIFICATION = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
    LC_MONETARY = "zh_CN.UTF-8";
    LC_NUMERIC = "zh_CN.UTF-8";
    LC_PAPER = "zh_CN.UTF-8";
    LC_TELEPHONE = "zh_CN.UTF-8";
    LC_TIME = "zh_CN.UTF-8";
  };
  # The niri module configures fcitx5 and desktop fonts.

  # == Console font (TTY) ==============================
  console = {
    earlySetup = true;
    font = "ter-132n";
    packages = [ pkgs.terminus_font ];
  };

  # == Minimal essentials ======================================================
  environment.systemPackages = with pkgs; [
    vim
    nano
    git
    usbutils
    alsaUtilsMinimal
    # Touchscreen-as-touchpad emulator for tablet use
    touchpad-emulator
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true; # initial setup convenience
    };
  };

  # == TouchpadEmulator ========================================================
  # Touchscreen-as-touchpad emulator (pkgs.touchpad-emulator).  nabu's input
  # devices (touchscreen "NVTCapacitiveTouchScreen", buttons "gpio-keys" and
  # "pm8941_resin") match the program's built-in device table, so it works
  # without patches.  It needs: the uinput module for the virtual mouse
  # device, permission for the `input` group on /dev/uinput (upstream's
  # LaunchTouchpadEmulator.sh instead uses a pkexec chmod hack), and the user
  # in `input` (above).  Volume keys still reach the desktop because the
  # program forwards quick taps as volume events.
  boot.kernelModules = [ "uinput" ];
  services.udev.extraRules = ''
    # TouchpadEmulator: allow the `input` group to create the virtual mouse
    # device.  Mirrors upstream's 10-uinput.rules.
    KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input"
  '';

  networking.networkmanager.package = networkManagerNabu;
  networking.modemmanager.enable = false;

  # Produce an uncompressed filesystem image for `fastboot flash linux`.
  nabu.image.compress = false;

  # Tablet power key: neither suspend nor power off. Screen on/off is left to
  # the compositor (niri) and the kernel, avoiding suspend on nabu causing a
  # brief "lights on then off" glitch.
  services.logind.settings.Login.HandlePowerKey = "ignore";

  # == Suspend debugging ======================================================
  # nabu wakes from s2idle within ~1s and the wake source is not visible with
  # the default configuration. The kernel-side debug facilities (PM_DEBUG
  # sysfs attributes, suspend/wakeup/irq tracepoints) are compiled into every
  # kernel — see pkgs/kernel/default.nix — while this specialisation adds a
  # separate boot entry (systemd-boot menu, title suffixed "suspend-debug")
  # carrying the extra kernel command line needed to catch the wake IRQ:
  #   pm_debug_messages  - verbose PM core messages during suspend/resume
  #   no_console_suspend - keep the console alive through late/noirq phases
  #   initcall_debug     - log initcall/device PM callback timing
  # Boot the "suspend-debug" entry from the systemd-boot menu to debug; the
  # default entry stays untouched. Remove this block once the wake source is
  # identified and fixed.
  specialisation."suspend-debug".configuration = {
    boot.kernelParams = [
      "pm_debug_messages"
      "no_console_suspend"
      "initcall_debug"
    ];
  };

  # The system is stateless enough for this; speeds up shutdown
  systemd.settings.Manager.DefaultTimeoutStopSec = "10s";
}
