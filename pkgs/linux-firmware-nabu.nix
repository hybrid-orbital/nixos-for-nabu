# Subset of linux-firmware for the Xiaomi Pad 5 (nabu).
#
# This is a whitelist: it copies the few directories and files nabu can use
# rather than copying everything and then deleting the unusable rest.  The full
# package is 791 MiB compressed (1.8 GiB raw: ~120 directories plus 650 loose
# top-level entries) and brings the assembled firmware environment to ~827 MiB
# of the system closure.  A keep-list has two advantages over a drop-list:
#   * the builder never runs chmod/rm on the read-only store tree — a drop-list
#     needs `chmod -R u+w` before it can delete anything;
#   * the result is auditable: whatever is not named below does not exist in the
#     output.
#
# Kept:
#   ath10k/                    onboard WCN3990 (WCN3990/hw1.0/{board-2.bin,
#                              firmware-5.bin} = WiFi BDF + stub) and the USB
#                              ath10k cards (QCA6174/QCA9377/…)
#   qca/                       crbtfw21.tlv + crnv21.bin = onboard Bluetooth,
#                              plus the USB QCA Bluetooth chips
#   qcom/sm8150 qcom/venus-*   our SoC's directory (only a640_zap.mbn, which
#                              pkgs/nabu-firmware.nix ships as well) and the venus
#                              video codec firmware, which the driver picks per
#                              SoC generation (nabu = venus-5.4)
#   ath6k ath9k_htc ar3k       Atheros USB WiFi/Bluetooth (AR600x/AR9271/AR3011)
#   brcm cypress libertas nxp  USB/SDIO WiFi and Bluetooth chips
#   rsi wfx atmel microchip
#   mediatek rtlwifi rtw88     MediaTek mt76 and Realtek USB WiFi/Bluetooth
#   rtw89 rtl_bt
#   mrvl/{cpt,pcie,sd,usb}*    Marvell USB/SDIO WiFi; this pattern is also what
#                              excludes mrvl/prestera (see below)
#   rtl_nic/                   RTL8153/8156 USB Ethernet (docks, USB-C dongles)
#   keyspan keyspan_pda        USB serial adapters whose chips need firmware
#   edgeport moxa
#   yamaha                     USB MIDI gadgets
#   cirrus/                    cs35l41 family for the speaker amps — the
#                              nabu-specific files come from
#                              pkgs/nabu-firmware.nix, this is the generic copy
#   Lontium/                   LT9611UXC MIPI/HDMI bridge firmware
#   loose  rt*.bin ar*.fw ar*.bin htc_*.fw ath3k-1.fw carl9170-1.fw
#          lbtf_usb.bin rsi_91x.fw vntwusb.fw whiteheat*.fw f2255usb.bin
#          ti_3410.fw ti_5052.fw usbdux*.bin
#                              Ralink/Atheros/Marvell/VIA USB blobs that live at
#                              the top level of the tree
#
# Not kept, and why (the big ones):
#   intel/                    357 MiB: x86 WiFi/Bluetooth/GPU/audio and every
#                             iwlwifi blob — PCIe/M.2 only, and nabu has no PCIe
#                             slot at all (the ~150 loose iwlwifi-*.ucode entries
#                             are symlinks into it)
#   qcom/, except above       174 MiB: other SoCs — x1e80100 (37 MiB), kaanapali,
#                             qdu100, sdm845, sm8250, sc8280xp, qcm2290, vpu, …
#                             There is no sensor firmware in qcom/ at all:
#                             Qualcomm sensors run inside the ADSP/SLPI, whose
#                             firmware is adsp.mbn from xiaomi-nabu-firmware.
#                             nabu's own ADSP/CDSP/modem/GPU/zap blobs likewise
#                             come from that package (priority 4 beats this one).
#   nvidia/ amdgpu/ i915/     154/88/27 MiB: x86 GPUs and CPU microcode; external
#   xe/ radeon/ amd/          GPUs would need PCIe or Thunderbolt
#   amd-ucode/ amdtee/ amdnpu/
#   netronome/ mellanox/      141/107/65/47 MiB: PCIe server NICs, and the
#   ath11k/ ath12k/ qed/      PCIe-only QCA6390/WCN6855/QCN9274 class cards
#   dpaa2/ liquidio/ cxgb4/
#   mrvl/prestera/            72 MiB of datacenter switch firmware hidden inside
#                             the otherwise useful mrvl/
#   ti/ ti-connectivity/      ti/ holds the audio amplifiers of specific laptops
#                             (ti/audio/tas2563, tas257x, tas2781); the 119 loose
#                             TAS2XXX*.bin and ~200 *-0xC.bin/-0x9.bin/-0xD.bin
#                             entries are symlinks into it.  ti-connectivity/ is
#                             SDIO/SPI-only TI WiFi and Bluetooth (wl12xx, wl18xx,
#                             cc33xx).
#   the rest                  DVB/video capture firmware (dvb-*, v4l-cx*,
#                             sms1xxx, isdbt/cmmb), legacy SCSI/network extras
#                             (qlogic, myri10ge, hfi1, bnx2*, cxgb*, phanfw),
#                             other-SoC firmware (arm, amlogic, meson, rockchip,
#                             imx, adaptec, …), and the ~530 loose top-level
#                             symlinks whose targets live in those directories
#
# Symlinks: the tree has 3056 of them (WHENCE-generated aliases), 1698 of which
# are inside the directories kept above.  Top-level aliases (e.g. mt7610u.bin ->
# mediatek/mt7610u.bin) are kept only when their target made it into the output,
# so the result can never contain a dangling link; the script asserts this.
#
# Result, measured: 183 MiB raw / 88 MiB compressed instead of 791 MiB, so the
# firmware environment drops from ~827 MiB to 100 MiB of the system closure.  65
# top-level entries instead of 524, and nothing is copied and then deleted (the
# earlier drop-list variant needed chmod + rm and came out at 252 MiB / 130 MiB,
# because it also kept whatever it had no reason to name).
#
#
# The source is the *built* `linux-firmware` output rather than its `.src`: the
# installed tree carries ~3000 symlinks generated from WHENCE at install time,
# which the plain git tree does not contain.  Copying files out of it leaves the
# output with no store references, so linux-firmware stays a build-time-only
# dependency and does not end up in the system closure.
{
  lib,
  runCommand,
  linux-firmware,
}:

let
  src = "${linux-firmware}/lib/firmware";

  # Whole directories to take verbatim.
  keepDirs = [
    # == Onboard: Qualcomm WCN3990 (WiFi + Bluetooth) =======================
    "ath10k" # WCN3990/hw1.0/{board-2.bin,firmware-5.bin} = WiFi BDF + stub
    "qca" # crbtfw21.tlv/crnv21.bin = Bluetooth; also USB QCA BT chips

    # == USB WiFi / Bluetooth adapters ======================================
    "ath6k" # AR600x USB
    "ath9k_htc" # AR9271 USB
    "ar3k" # AR3011/AR3012 Bluetooth
    "brcm" # brcmfmac USB/SDIO
    "cypress" # same silicon as brcm, under the cypress/ name
    "libertas" # Marvell 8xxx USB/SDIO
    "mediatek" # mt76: mt7601u/mt7610u/mt7662/mt7921/7922/7925
    "nxp" # NXP 88W8xxx USB/SDIO
    "rsi" # Redpine RS9113
    "rtlwifi" # Realtek RTL8188/8192 USB/SDIO
    "rtw88" # Realtek RTL8821/8822 USB
    "rtw89" # Realtek RTL8851/8852/8922 USB (WiFi 6)
    "rtl_bt" # Realtek USB Bluetooth
    "wfx" # Silicon Labs WF200
    "atmel" # AT76c50x USB
    "microchip" # WILC1000

    # == USB Ethernet =======================================================
    "rtl_nic" # RTL8152/8153/8156 — the Ethernet port of most USB-C docks

    # == USB serial adapters whose chips need firmware ======================
    "keyspan"
    "keyspan_pda"
    "edgeport" # TI USB serial
    "moxa"

    # == USB audio ==========================================================
    "yamaha"

    # == Onboard audio: speaker amplifiers ==================================
    "cirrus"

    # == Display bridges ====================================================
    "Lontium" # LT9611UXC MIPI/HDMI
  ];

  # Subdirectories of directories we do not take as a whole.  The mrvl patterns
  # are what excludes mrvl/prestera (72 MiB of switch firmware).
  keepSubdirs = [
    "mrvl/cpt*"
    "mrvl/pcie*"
    "mrvl/sd*"
    "mrvl/usb*"
    # our SoC's directory and the venus codec firmware (nabu uses venus-5.4;
    # all generations together are 2 MiB)
    "qcom/sm8150"
    "qcom/venus-*"
  ];

  # Loose top-level files (globs allowed).
  keepTopFiles = [
    "rt*.bin" # Ralink USB WiFi (rt73/rt2870/rt3071) and RT3290 Bluetooth
    "ar*.fw" # Atheros USB (AR5523/AR7010/AR9170)
    "ar*.bin"
    "htc_*.fw" # htc_9271 (AR9271 USB) / htc_7010
    "ath3k-1.fw" # Atheros USB Bluetooth
    "carl9170-1.fw"
    "lbtf_usb.bin" # Marvell Libertas USB WiFi
    "rsi_91x.fw" # Redpine RS9113
    "vntwusb.fw" # VIA VT6656
    "whiteheat*.fw" # USB serial
    "f2255usb.bin"
    "ti_3410.fw"
    "ti_5052.fw"
    "usbdux*.bin"
  ];
in
runCommand "linux-firmware-nabu-${linux-firmware.version}"
  {
    # Firmware blobs must not be touched (same reason as upstream).
    dontFixup = true;
    meta = {
      description = "linux-firmware subset for the Xiaomi Pad 5 (nabu) plus common external devices";
      homepage = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git";
      license = lib.licenses.unfreeRedistributableFirmware;
      platforms = lib.platforms.linux;
      # Same value as upstream linux-firmware, so device firmware
      # (xiaomi-nabu-firmware, priority 4) still wins on collisions.
      priority = 6;
    };
  }
  ''
    fw="$out/lib/firmware"
    src=${src}
    mkdir -p "$fw"
    cd "$src"

    # 1. Whole directories, taken verbatim.  cp -a preserves the read-only store
    #    modes, and nothing is written into them afterwards.
    for d in ${lib.concatStringsSep " " keepDirs}; do
      cp -a "$d" "$fw/"
    done

    # 2. Individual subdirectories of directories we do not want as a whole.  The
    #    parent (mrvl/, qcom/) has to be created here: cp cannot write into a
    #    parent it has just created read-only, and copying the whole parent would
    #    drag in the unlisted siblings.  These two synthetic directories get the
    #    default mode; Nix normalises permissions when the output is added to the
    #    store, so the shipped tree is dr-xr-xr-x throughout, like upstream.
    for p in ${lib.concatStringsSep " " keepSubdirs}; do
      parent=''${p%%/*}
      mkdir -p "$fw/$parent"
      cp -a "$p" "$fw/$parent/"
    done

    # 2. Kept loose top-level files (unmatched globs stay literal and are skipped).
    for f in ${lib.concatStringsSep " " keepTopFiles}; do
      [ -e "$f" ] || continue
      cp -a "$f" "$fw/"
    done

    # 3. Top-level aliases whose target we actually shipped (mt7610u.bin ->
    #    mediatek/mt7610u.bin and friends).  Testing against the tree we just
    #    copied means an alias can never dangle, whatever the lists above say.
    for f in *; do
      [ -L "$f" ] || continue
      t=$(readlink -f "$f")
      case "$t" in
        "$src"/*) rel=''${t#"$src"/} ;;
        *) continue ;;
      esac
      if [ -e "$fw/$rel" ]; then
        cp -a "$f" "$fw/"
      fi
    done

    # 4. Assert that nothing dangles, and report what we shipped.
    dangling=$(find "$fw" -xtype l | wc -l)
    echo "dangling symlinks: $dangling"
    test "$dangling" -eq 0
    echo "top-level entries: $(ls "$fw" | wc -l)"
    du -sh "$fw"
  ''
