# TouchpadEmulator (CalcProgrammer1) — emulates a laptop-style touchpad from
# the nabu touchscreen, with volume-key mode switching.  nabu is already in
# the program's built-in device table ("Xiaomi Pad 5 Pro" row: touchscreen
# "NVTCapacitiveTouchScreen", buttons "gpio-keys" and "pm8941_resin" match
# this device exactly), so no source patch is required.
#
# Upstream's LaunchTouchpadEmulator.sh grants device access with a pkexec
# chmod hack; on NixOS the configuration instead grants the `input` group
# access to uinput via udev rules (see nixos/configuration.nix), so only the
# binary is packaged and the desktop entry execs it directly.
{
  lib,
  stdenv,
  fetchFromGitLab,
  pkg-config,
  dbus,
  dbus-glib,
  glib,
}:

stdenv.mkDerivation {
  pname = "touchpad-emulator";
  version = "0-unstable-2025-10-02";

  src = fetchFromGitLab {
    domain = "gitlab.com";
    owner = "CalcProgrammer1";
    repo = "TouchpadEmulator";
    rev = "aa6a4871658177880dcb7f140d15563546c1a2d6";
    hash = "sha256-RStmmUJbGbm7jaRMRozZ2UHEWQVZBt8T1z3aQRUAGaA=";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    dbus
    dbus-glib
    glib
  ];

  # Same compile line as upstream's Makefile (the `clean` target runs
  # `git clean -dfx`, so a full make invocation is best avoided).
  buildPhase = ''
    runHook preBuild
    $CC -Wall $(pkg-config --cflags dbus-1 dbus-glib-1) TouchpadEmulator.c \
      -ldbus-1 -ldbus-glib-1 -lpthread -o TouchpadEmulator
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 TouchpadEmulator "$out/bin/TouchpadEmulator"
    install -Dm644 TouchpadEmulator.png \
      "$out/share/icons/hicolor/64x64/apps/TouchpadEmulator.png"
    install -Dm644 TouchpadEmulator.svg \
      "$out/share/icons/hicolor/scalable/apps/TouchpadEmulator.svg"
    # Upstream's Exec points at LaunchTouchpadEmulator.sh (pkexec chmod hack);
    # with proper udev permissions the plain binary is enough.
    install -Dm644 TouchpadEmulator.desktop \
      "$out/share/applications/TouchpadEmulator.desktop"
    substituteInPlace "$out/share/applications/TouchpadEmulator.desktop" \
      --replace-fail 'Exec=LaunchTouchpadEmulator.sh' 'Exec=TouchpadEmulator'
    runHook postInstall
  '';

  meta = {
    description = "Virtual mouse for Linux phones and tablets that emulates a touchpad from the touchscreen";
    longDescription = ''
      Emulates a laptop-style touchpad device using a touchscreen: one finger
      moves the cursor, taps click, two fingers scroll.  Volume keys switch
      between touchscreen and touchpad modes.  Device support for the Xiaomi
      Pad 5 (nabu) is built in.
    '';
    homepage = "https://gitlab.com/CalcProgrammer1/TouchpadEmulator";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "TouchpadEmulator";
  };
}
