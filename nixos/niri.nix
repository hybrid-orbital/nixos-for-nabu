# Niri + Noctalia desktop for nabu.
# The greeter starts niri-session, which imports PATH into the user manager
# and runs XDG autostart applications, including the input method.
{
  config,
  pkgs,
  ...
}:

let
  nabuUser = config.users.users.nabu;
  niriConfigDir = "${nabuUser.home}/.config/niri";

  initialUserConfig = pkgs.writeText "niri-user-config.kdl" ''
    include "/etc/niri/config.kdl"
  '';

  # Pin the DSI-1 panel to the KTZ8866 backlight device. Noctalia's automatic
  # backlight-to-output matching only handles backlights whose sysfs `device`
  # parent is the DRM connector (eDP/DP/HDMI); nabu's backlight is a separate
  # I2C chip (ktz8866-backlight), so the auto path skips it and brightness is
  # reported as unavailable. A dedicated file keeps user edits to config.toml
  # intact (Noctalia merges every *.toml in this directory).
  initialNoctaliaBrightnessConfig = pkgs.writeText "noctalia-nabu-brightness.toml" ''
    [brightness.monitor.DSI-1]
    backend = "backlight"
    backlight_device = "ktz8866-backlight"
  '';

  # Toggle the on-screen keyboard for tablet input.
  wvkbdToggle = pkgs.writeShellScriptBin "wvkbd-toggle" ''
    WVKBD_EXEC="wvkbd-mobintl"
    if ${pkgs.procps}/bin/pgrep -x "$WVKBD_EXEC" > /dev/null; then
      ${pkgs.procps}/bin/pkill -x "$WVKBD_EXEC"
    else
      ${pkgs.wvkbd}/bin/wvkbd-mobintl &
    fi
  '';
in
{
  # == Compositor =============================================================
  programs.niri = {
    enable = true;
    useNautilus = false;
  };

  # Seed a writable user config on first boot. C copies a regular file only
  # when absent, preserving subsequent user edits and Noctalia theme includes.
  systemd.tmpfiles.rules = [
    "d ${nabuUser.home}/.config 0700 nabu ${nabuUser.group} - -"
    "d ${niriConfigDir} 0700 nabu ${nabuUser.group} - -"
    "C ${niriConfigDir}/config.kdl 0600 nabu ${nabuUser.group} - ${initialUserConfig}"
    "d ${nabuUser.home}/.config/noctalia 0700 nabu ${nabuUser.group} - -"
    "C ${nabuUser.home}/.config/noctalia/90-nabu-brightness.toml 0600 nabu ${nabuUser.group} - ${initialNoctaliaBrightnessConfig}"
  ];

  # == Desktop shell ==========================================================
  programs.noctalia = {
    enable = true;
    # NetworkManager / bluetooth / UPower / power-profiles-daemon
    recommendedServices.enable = true;
  };

  # == Login (noctalia-greeter -> greetd -> niri-session) ========================
  services.displayManager.noctalia-greeter = {
    enable = true;
    # Upstream v1.3.1 lacks absolute-input mapping on transformed outputs and
    # drops tablet (pen) events entirely. Two independent patches, one per
    # issue: map-cursor-to-output fixes touch on rotated panels;
    # tablet-as-pointer forwards pen events to wl_pointer. Pending upstream.
    package = pkgs.noctalia-greeter.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ../pkgs/noctalia-greeter/noctalia-greeter-map-cursor-to-output.patch
        ../pkgs/noctalia-greeter/noctalia-greeter-tablet-as-pointer.patch
      ];
    });
    settings = {
      session.default = "niri";
      user.default = "nabu";
      idle.timeout = 0; # Keep the greeter display awake.
      keyboard.layout = "us";
      # The greeter has its own compositor and does not read niri's config.
      # Pin its absolute inputs to the built-in panel as well as rotating it.
      output.name = "DSI-1";
      output.transforms = "DSI-1:270";
    };
  };

  # == Audio ==================================================================
  services.pipewire = {
    enable = true;
    audio.enable = true;
    pulse.enable = true;
  };

  # == Chinese input method ===================================================
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [
      qt6Packages.fcitx5-chinese-addons
      fcitx5-gtk
    ];
  };

  # == Fonts ==================================================================
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  # == Desktop utilities ======================================================
  programs.thunar.enable = true;
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # Native X11 applications run through niri's on-demand Xwayland bridge.
  programs.xwayland.enable = true;

  environment.systemPackages = with pkgs; [
    foot
    wvkbd
    wvkbdToggle
    xwayland-satellite
    wl-clipboard
    xdg-utils
  ];

  # Validate on the build machine, including when cross-compiling for aarch64.
  # The writable user entry point includes this shared configuration first.
  environment.etc."niri/config.kdl".source = pkgs.runCommand "validated-niri-config.kdl" { } ''
    ${pkgs.buildPackages.niri}/bin/niri validate --config ${./niri.kdl}
    cp ${./niri.kdl} "$out"
  '';
}
