# Custom package set for nixos-for-nabu.
# Exposed as an overlay so `pkgs.kernel-sm8150` etc. work inside the
# NixOS configuration.
final: prev: {
  # Mainline sm8150 kernel (6.17) with nabu support
  kernel-sm8150 = final.callPackage ./kernel { };

  # Qualcomm protection domain mapper (missing from nixpkgs)
  pd-mapper = final.callPackage ./pd-mapper.nix { };

  # Device firmware from the postmarketOS firmware repo
  xiaomi-nabu-firmware = final.callPackage ./nabu-firmware.nix { };

  # linux-firmware whitelisted down to what nabu + common USB devices use
  # (88 MiB compressed instead of 791 MiB) — see the file header for the list
  linux-firmware-nabu = final.callPackage ./linux-firmware-nabu.nix { };

  # Touchscreen-as-touchpad emulator for tablet use
  touchpad-emulator = final.callPackage ./touchpad-emulator.nix { };

  # ALSA UCM profile for sm8150-nabu audio — KEPT AS A FALLBACK.
  # The "correct" long-term fix is to load this UCM profile, but ALSA only
  # searches the alsa-ucm-conf datadir (share/alsa/ucm2), never /etc, and
  # WirePlumber/ACP currently has no working UCM for this card.  The current
  # speaker fix therefore BYPASSES UCM (see nixos/hardware-nabu.nix).
  #
  # NOTE: do NOT override `alsa-ucm-conf` to merge this in.  That changes
  # alsa-ucm-conf's store path and forces a rebuild of alsa-lib and the whole
  # audio stack.  This package is intentionally left unmerged.
  nabu-alsa-ucm = final.stdenv.mkDerivation {
    pname = "nabu-alsa-ucm";
    version = "1";
    src = ./alsa-ucm;
    installPhase = ''
      mkdir -p "$out/share/alsa/ucm2/conf.d/snd_soc_sm8150" \
               "$out/share/alsa/ucm2/Xiaomi/nabu"
      install -Dm644 sm8150.conf \
        "$out/share/alsa/ucm2/conf.d/snd_soc_sm8150/snd_soc_sm8150.conf"
      install -Dm644 HiFi.conf \
        "$out/share/alsa/ucm2/Xiaomi/nabu/HiFi.conf"
    '';
    meta = {
      description = "ALSA UCM profiles for Xiaomi Pad 5 (nabu) — fallback";
      platforms = final.lib.platforms.linux;
    };
  };
}
