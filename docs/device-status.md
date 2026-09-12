**English** | [简体中文](zh_CN/device-status.md)

# Device support status

[Back to project home](../README.md)

Baseline: `v0.1.0-alpha` / `c26c2c1`, 2026-09-07. "Verified" refers to results
reported by the maintainer on the available nabu device; it does not mean that all
hardware batches, firmware versions and use cases are covered. Enabling a feature
in the configuration does not mean that the hardware behind it has been validated.

## Verified release path

- systemd-boot boots the current NixOS image and provides the native generation
  menu.
- The niri + Noctalia desktop image has been released and works on hardware.
- The landscape systemd-boot menu is verified; the greeter and desktop are
  configured with the matching orientation.
- The pen is bound to the internal `DSI-1` output in the configuration and rotates
  with the output; see the [desktop notes](desktop.md) for details.

## Known issues

| Area | Current state | Follow-up |
| --- | --- | --- |
| Camera | Maintainer confirms it is unavailable | Check the kernel driver, device tree, firmware and the userspace camera stack |
| Low-power suspend | Maintainer confirms s2idle is reachable and the Bluetooth UART immediate-wake bug is fixed and validated on hardware | Power key, auto-suspend, display resume and standby power |
| Boot reliability | Boots occasionally fail; cause undetermined | Record cold boots/warm reboots, the failing stage, logs, and hardware/firmware versions separately |
| Power key | Deliberately ignored for now | Redesign key behaviour together with display and suspend validation |
| rootfs size | The current desktop image is large | Measure the closure, split variants, drop unnecessary dependencies |

`services.logind.settings.Login.HandlePowerKey = "ignore"` together with niri's
`disable-power-key-handling` currently avoids existing suspend/screen-off problems.
These are temporary behavioural constraints, not a finished power-management
solution. Locking, screen-off, low-power suspend, display resume and unlock should
be tested separately.

The random Wi-Fi MAC address across reboots is resolved: the generic `board-2.bin`
carries no MAC, so a kernel patch
(`pkgs/kernel/patches/0002-nabu-ath10k-mac-address.patch`) derives a stable
locally-administered address from the SMBIOS board serial, overridable with the
`ath10k_core.macaddr=` module parameter. The approach comes from
[TwinbornPlate75/linux-nabu](https://github.com/TwinbornPlate75/linux-nabu).

Suspend-to-idle waking up immediately is fixed, and the maintainer has confirmed on
hardware that entering suspend works. nabu's WCN3991 Bluetooth UART (`uart13` /
`c8c000.serial`, alias `hsuart0`) is a serdev whose port stays open, so the runtime
PM usage count never reaches zero at suspend time: `qcom_geni_serial_runtime_suspend()`
never runs, `geni_se_resources_off()` is skipped, the sleep pinctrl
(`qup_uart13_sleep`: GPIO input with a `gpio46` pull-up) is never applied and the
QUP13 pads stay in their `bias-disable` default state. Together with the Bluetooth
controller's traffic and the TLMM behaviour of latching edge-IRQ status while
masked, the dedicated wake IRQ fires the moment `dpm_suspend_noirq` arms it, so the
system resumes as soon as it has entered suspend-to-idle. The fix backports
upstream commit `d0cd9c8d0fd5` ("serial: qcom-geni: add force suspend/resume to
system sleep callbacks" by **Praveen Talari** `<praveen.talari@oss.qualcomm.com>`,
merged via tty-next for v6.18-rc4 and absent from 6.17.y) as
`pkgs/kernel/patches/0005-qcom-geni-serial-force-suspend-system-sleep.patch`; the
patch keeps the upstream author, commit message and sign-off chain. Bluetooth
operation and the wake capability are unchanged; what is still missing is a record
for the power key, auto-suspend, display resume and standby power.

## Configured, but needing fuller validation records

The code includes UFS, Wi-Fi, graphics, panel/backlight, touch, pen, audio and
Qualcomm service support. The speakers, for example, still rely on a specific ALSA
routing setup, and an enabled service does not prove that all audio inputs and
outputs work. Bluetooth, sensors, external devices and different storage batches
should be reported per device and version; without reports they are neither
automatically "working" nor "broken".

The Android menu and the Reboot2Android program are deployed by the configuration;
when migrating firmware, reflashing or publishing a new image, the Android return
path still needs to be part of regression testing.

## How to provide a useful report

Please include:

1. Image tag/commit, native or cross-built, and whether the configuration was
   modified.
2. Aloha/DBKP version, Secure Boot state, device memory and storage specifications
   (chip batch when known).
3. Reproduction steps, expected and actual behaviour; count successes/failures for
   cold boots and warm reboots separately.
4. Whether the failure stops at the menu, the EFI stub, the kernel log, the greeter
   or the desktop; whether SSH is still reachable.
5. `/proc/cmdline`, `systemctl --failed` and the relevant journal; see
   [boot diagnostics](boot-logging.md) for how to collect them.

Check logs for usernames, addresses and network names before publishing them. One
recovered boot, one usable desktop session or one `suspend` command returning is
not enough to close an intermittent problem.
