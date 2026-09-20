# Mainline kernel for the Xiaomi Pad 5.
#
# Unlike ../sm8150-fork (which builds the pinned sm8150-mainline fork from its
# own defconfig), this package starts from nixpkgs' `linux_latest` and applies
# the downstream sm8150/nabu support that is not upstream yet:
#
#   0001  device tree (sm8150-xiaomi-nabu.dts + the sm8150/pm8150 pieces it
#         needs, including the WCD9340 binding and the NB of the sm8150 dtsi)
#   0002  DRM blank notifier + Novatek NT36523 "nabu csot" panel support
#   0003  NT36523 (nt36xxx) SPI touchscreen driver
#   0004  SM8150 ASoC machine driver (WCD9340/SLIMBUS sound card)
#   0005  charging stack: qcom_fg fuel gauge + idtp9418 wireless charger
#   0006  of/property remote-endpoint fix + MAINTAINERS entry
#   0007  runtime fixes (ath10k MAC address + thermal, Adreno suspend,
#         qcom-geni serial force suspend during system sleep)
#
# The patches are a rebase of the sm8150-mainline tree (branch sm8150/6.17,
# tag v6.17.0-sm8150) onto the version nixpkgs ships.  Keep them ordered: each
# one applies on top of the previous ones.
#
# nixpkgs' common config stays enabled (default for `buildLinux`): this is a
# stock upstream tree, so a standard NixOS capable .config is the right base
# and only the nabu specific options in ./configs/nabu.config are merged on
# top.  `ignoreConfigErrors` is not relaxed: on arm64 an option that kconfig
# cannot satisfy is a build error, which keeps the fragment honest.
#
# Both `enableCommonConfig` and `autoModules` keep their nixpkgs defaults: the
# common config is written for the "answer m to everything" behaviour, so
# turning autoModules off silently drops over a hundred settings that are
# needed for a NixOS userspace (leaving it on costs build time instead; see
# ./configs/nabu.config for the details).
{
  lib,
  linux_latest,
  ...
}@args:

let
  extraConfig = builtins.readFile ./configs/nabu.config;
  requiredConfig = ./configs/required-nabu.config;

  kernel = linux_latest.override {
    kernelPatches = linux_latest.kernelPatches ++ [
      {
        name = "nabu-dt";
        patch = ./patches/0001-dt-qcom-sm8150-add-xiaomi-nabu.patch;
      }
      {
        name = "nabu-drm-notifier-and-panel";
        patch = ./patches/0002-drm-add-notifier-and-nabu-panel-support.patch;
      }
      {
        name = "nabu-touchscreen-nt36523";
        patch = ./patches/0003-input-add-nt36523-touchscreen.patch;
      }
      {
        name = "nabu-sound-card";
        patch = ./patches/0004-asoc-qcom-add-sm8150-sound-card.patch;
      }
      {
        name = "nabu-power-supply";
        patch = ./patches/0005-power-supply-add-nabu-charging.patch;
      }
      {
        name = "nabu-of-property";
        patch = ./patches/0006-of-and-maintainers.patch;
      }
      {
        name = "nabu-runtime-fixes";
        patch = ./patches/0007-nabu-runtime-fixes.patch;
      }
      {
        # UFS/DSI clock stability: settle time before regmap clock toggles and
        # a real halt check for the UFS PHY symbol clocks (see the patch header
        # and the README).  Without it the controller can be left with a clock
        # stuck in the previous state, which shows up as a stalled or flaky
        # boot and as DSI link glitches.
        name = "nabu-qcom-clock-stability";
        patch = ./patches/0008-clk-qcom-ufs-dsi-clock-stability.patch;
      }
    ];

    extraConfig = extraConfig;

    extraMeta = {
      branch = "nixpkgs/linux_latest";
      description = "Mainline Linux kernel (nixpkgs linux_latest) for the Xiaomi Pad 5 (nabu)";
      maintainers = with lib.maintainers; [ ];
      platforms = [ "aarch64-linux" ];
    };
  };
in
kernel.overrideAttrs (previousAttrs: {
  # Independently verify the resolved config, including implied dependencies.
  # Every line of ./configs/required-nabu.config must be present verbatim in
  # the post-kconfig .config; a requirement of "CONFIG_FOO=m" is also accepted
  # as "CONFIG_FOO=y", because building a driver in instead of as a module
  # keeps both the root filesystem and the panel reachable.
  postConfigure = (previousAttrs.postConfigure or "") + ''
    echo ">>> checking nabu boot-critical kernel configuration"
    while IFS= read -r requirement; do
      case "$requirement" in
        ""|'#'*) continue ;;
      esac
      if grep -Fqx "$requirement" "$buildRoot/.config"; then
        continue
      fi
      if [[ "$requirement" == *=m ]] &&
         grep -Fqx "''${requirement%=m}=y" "$buildRoot/.config"; then
        continue
      fi
      echo "ERROR: required nabu kernel setting is missing: $requirement" >&2
      exit 1
    done < ${requiredConfig}
  '';
})
