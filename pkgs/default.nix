# Custom package set for nixos-for-nabu.
# Exposed as an overlay so `pkgs.kernel-sm8150` etc. work inside the
# NixOS configuration.
final: prev:
let
  # Every kernel this project ships, keyed by the name used in
  # `nabu.kernel.name` (see pkgs/kernel/default.nix).
  kernels = final.callPackage ./kernel { };
in
{
  inherit kernels;

  # Pinned sm8150-mainline fork (6.17) with nabu support: the default kernel.
  kernel-sm8150 = kernels."sm8150-fork";

  # nixpkgs linux_latest + the downstream nabu patches: the kernel under test
  # for the next kernel version.
  kernel-nabu-mainline = kernels."mainline-latest";

  # Qualcomm protection domain mapper (missing from nixpkgs)
  pd-mapper = final.callPackage ./pd-mapper.nix { };

  # Device firmware from the postmarketOS firmware repo
  xiaomi-nabu-firmware = final.callPackage ./nabu-firmware.nix { };

  # linux-firmware whitelisted down to what nabu + common USB devices use
  # (88 MiB compressed instead of 791 MiB) — see the file header for the list
  linux-firmware-nabu = final.callPackage ./linux-firmware-nabu.nix { };

  # Touchscreen-as-touchpad emulator for tablet use
  touchpad-emulator = final.callPackage ./touchpad-emulator.nix { };

  # ALSA UCM profile for sm8150-nabu audio (loaded via ALSA_CONFIG_UCM2,
  # see nixos/hardware-nabu.nix).
  #
  # ALSA identifies the card by the fields the kernel sets in
  # sound/soc/qcom/sm8150.c and the DTS, not by the platform driver or module
  # name:
  #   CardDriver   = "sm8150"        (card->driver_name = DRIVER_NAME)
  #   CardLongName = "Xiaomi Pad 5"  (DTS &sound { model = ... })
  # "snd-sm8150" (platform driver) and "snd_soc_sm8150" (module/Kconfig name)
  # are never queried.  alsa-lib probes, in this order:
  #   ucm2/conf.d/<CardDriver>/<CardLongName>.conf
  #   ucm2/conf.d/<CardDriver>/<CardDriver>.conf
  # so the master file has to be conf.d/sm8150/sm8150.conf.
  nabu-alsa-ucm = final.stdenv.mkDerivation {
    pname = "nabu-alsa-ucm";
    version = "1";
    src = ./alsa-ucm;
    installPhase = ''
      mkdir -p "$out/share/alsa/ucm2/conf.d/sm8150" \
               "$out/share/alsa/ucm2/Xiaomi/nabu"
      install -Dm644 sm8150.conf \
        "$out/share/alsa/ucm2/conf.d/sm8150/sm8150.conf"
      install -Dm644 HiFi.conf \
        "$out/share/alsa/ucm2/Xiaomi/nabu/HiFi.conf"
    '';
    meta = {
      description = "ALSA UCM profile for Xiaomi Pad 5 (nabu)";
      platforms = final.lib.platforms.linux;
    };
  };

  # alsa-lib resolves ucm2 through the symlink
  #   <alsa-lib>/share/alsa/ucm2 -> <alsa-ucm-conf>/share/alsa/ucm2
  # baked into its own store path, so a separate profile package is invisible
  # to it.  ALSA_CONFIG_UCM2 *replaces* that search directory (alsa-lib
  # src/ucm/utils.c), so expose the stock alsa-ucm-conf tree plus the nabu
  # profile as one merged ucm2 root and point the variable at it (see
  # nixos/hardware-nabu.nix).
  #
  # NOTE: do NOT override `alsa-ucm-conf` itself instead.  That changes its
  # store path and forces a rebuild of alsa-lib and the whole audio stack.
  alsa-ucm-conf-nabu = final.runCommand "alsa-ucm-conf-nabu" { } ''
    mkdir -p "$out/share/alsa/ucm2"
    cp -a ${final.alsa-ucm-conf}/share/alsa/ucm2/. "$out/share/alsa/ucm2/"
    chmod -R u+w "$out/share/alsa/ucm2"
    cp -a ${final.nabu-alsa-ucm}/share/alsa/ucm2/. "$out/share/alsa/ucm2/"
  '';
}
