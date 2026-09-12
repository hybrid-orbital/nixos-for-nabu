**English** | [简体中文](zh_CN/boot-logging.md)

# Boot diagnostics

[Back to project home](../README.md) · [Device status](device-status.md)

The current alpha image has been verified to boot, but the maintainer still reports
occasional boot failures whose cause is not yet determined. The notes below are for
locating the problem and do not mean it is fixed.

The logging parameters are centralised in `nixos/boot.nix`; the initrd load order for
the panel, backlight and storage drivers is in `nixos/hardware-nabu.nix`. Boot
logging is kept on, the Plymouth splash screen is disabled, and enabling a large
amount of debug output or forcing an early screen takeover by default is avoided.

## Which stages are visible

- EFI stub: `efi=debug` requests debug output from the firmware console during
  loading; whether it is shown depends on the UEFI implementation.
- Linux kernel: the console log level is set to 7 everywhere, with timestamps and a
  4 MiB log buffer. Debug messages that were already produced stay in the kernel
  buffer and can be read through the journal, but they no longer flood the screen.
- initrd: includes the backlight and panel drivers, which udev loads on demand; it
  neither forces early loading nor disables fbcon's deferred-takeover policy.
  systemd shows the boot status and service output uses NixOS' default logging
  channel.
- Normal system: shows the systemd boot status, the manager log level is info, and
  journald collects the logs. Logs remain readable through the journal once the
  greeter has started.

The current device tree for the Xiaomi Pad 5 provides no simple-framebuffer. After
Linux takes over, the screen must wait for MSM DRM, the panel and the backlight to be
initialised, and logging parameters alone cannot guarantee a picture from the very
first kernel instruction. Messages before the screen lights up are written to the
kernel buffer, but excessive logging can still overwrite older records.
To observe a hang live before the display driver initialises, you need a confirmed,
working hardware serial port and earlycon configuration; this document does not
assume an unknown UART address and does not enable the unverified `earlycon=efifb`.

## Applying the configuration

Run this in the repository directory on the tablet:

```sh
sudo nixos-rebuild boot --flake .#nabu
sudo reboot
```

These changes require regenerating the initrd and boot parameters and take effect
after a reboot. `switch` also updates the next boot's configuration, but it cannot
change the boot parameters of the currently running kernel.

## Reading and exporting

```sh
cat /proc/cmdline
sudo journalctl --list-boots
sudo journalctl -b -k -o short-monotonic
sudo journalctl -b -o short-monotonic
sudo journalctl -b -1 -k -o short-monotonic
sudo journalctl -b -1 -o short-monotonic
sudo journalctl -b -o short-monotonic --no-pager > boot-current.log
sudo journalctl -b -1 -o short-monotonic --no-pager > boot-previous.log
```

`/proc/cmdline` should contain exactly one `loglevel=7` and no `quiet`, `splash`,
`ignore_loglevel`, `initcall_debug` or `fbcon=nodefer`.
To inspect the initrd switch-root process and module loading:

```sh
sudo journalctl -b -u initrd-switch-root.service -u systemd-modules-load.service
sudo journalctl -b -k --no-pager | grep -Ei 'fbcon|drm|novatek|ktz8866|ath10k'
```

The persistent journal limit is 256 MiB and the normal sync interval is 30 seconds.
Hangs or sudden power loss before the root filesystem is writable and the logs have
been flushed, and messages already overwritten in the buffer, are not guaranteed to
be recoverable through `journalctl -b -1`.

## Grey screen after a penguin and logs appear

A penguin and `[timestamp]` messages mean the Linux framebuffer console has already
displayed content, so the failure should be investigated in the display driver
operation and mode switching that follow; this does not prove that the whole system
hung.

When detailed logging was first added, `fbcon=nodefer`, active loading of the
panel/backlight drivers, `initcall_debug` and systemd debug logging to kmsg were
enabled as well. Those settings change the initialisation order or add console
output load. Users reported occasional grey screens after that change, so those
settings were withdrawn, keeping timestamps, the larger buffer, boot status and the
persistent journal. The current release runs on hardware but still has occasional
boot failures. Which item triggers it is not yet determined, and this is not grounds
for considering the grey-screen or boot-reliability problem fixed.

Proceed in the following order and record several warm reboots and cold boots for
each step:

1. Apply the current configuration and confirm that `/proc/cmdline` has been
   updated; an intermittent problem cannot be ruled out by one successful boot.
2. If the grey screen persists, select the boot entry in the systemd-boot menu,
   press `e`, append `systemd.unit=multi-user.target` temporarily to the end of the
   parameters and boot with Enter. It applies only to that boot and does not start
   the graphical login. If the text boot is stable, continue by checking the
   greetd/niri and DRM switching; if it also goes grey, continue with the kernel
   display path or an even earlier boot stage.
3. Compare against the generation from before the logging change, selected in the
   boot menu. The old configuration also enabled Plymouth, so a stable old version
   only shows that this group of boot settings is worth suspecting; it does not
   pin down a single parameter.

If SSH is still reachable during a grey screen, export the current boot log first;
the Wi-Fi MAC address changes, so confirm the current IP. After a successful boot,
check the times in `journalctl --list-boots` and then pick the boot ID of the failed
boot. Do not assume that `-b -1` is the grey-screen boot: a much earlier failed boot
may have no persistent record.

```sh
sudo journalctl -b -k --no-pager > kernel-current.log
sudo journalctl -b -u greetd.service --no-pager
sudo journalctl -b -k --no-pager | grep -Ei 'drm|msm|dsi|dpu|panel|gmu|adreno|firmware|timeout|lockup|stall'
```

For more detailed kernel initialisation tracing, add `initcall_debug` for a single
boot in the boot menu, keep `loglevel=7` and export the messages from the journal
afterwards. Avoid restoring all debug and display-timing changes at the same time.

References: [kernel boot parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html),
[fbcon takeover behaviour](https://docs.kernel.org/fb/fbcon.html),
[systemd 261 boot parameter notes](https://github.com/systemd/systemd/blob/v261/man/systemd.xml).
