**English** | [简体中文](zh_CN/desktop.md)

# niri + Noctalia desktop

[Back to project home](../README.md) · [Device status](device-status.md)

This is the default desktop of the current release image. The camera is
unavailable and occasional boot failures remain; low-power suspend can reach s2idle
again (the Bluetooth UART immediate-wake bug is fixed and validated on hardware).
The power key is deliberately ignored, and locking the screen does not mean
screen-off or low-power suspend. Other desktop variants are still on the
[roadmap](roadmap.md).

`nixos/niri.kdl` manages layout, input devices, window rules and key bindings;
`nixos/niri.nix` manages NixOS packages, services, the greeter and the KDL build
check. The current configuration corresponds to niri 26.04 and Noctalia 5.0.1 in
`flake.lock`.

## Common shortcuts

Once the desktop is running, `Mod` is the Super / Windows key on the keyboard.
A shortcut help overlay appears on first login and can be reopened at any time with
`Mod+Shift+/`.

| Shortcut | Action |
| --- | --- |
| `Mod+Shift+/` | Show shortcut help |
| `Mod+Return` / `Mod+E` | Foot terminal / Thunar file manager |
| `Mod+Space` / `Mod+S` / `Mod+,` | Noctalia launcher / control centre / settings |
| `Alt+Tab` | Noctalia window switcher panel |
| `Mod+Shift+K` | Show or hide the wvkbd virtual keyboard |
| `Super+Alt+L` | Noctalia lock screen |
| `Mod+←↓↑→` or `Mod+H/J/K/L` | Switch columns left/right, switch windows within a column up/down |
| The direction keys above with `Ctrl` | Move columns or windows within a column |
| `Mod+Home/End` | Focus the leftmost / rightmost column; with `Ctrl`, move the current column |
| `Mod+Shift+<direction>` | Switch monitors; with `Ctrl`, move the column to that monitor |
| `Mod+PageUp/PageDown` or `Mod+I/U` | Switch to the previous / next workspace |
| The workspace keys above with `Ctrl` / `Shift` | Move the current column to a workspace / reorder workspaces |
| `Mod+1…9` | Switch to a dynamic workspace by index; with `Ctrl`, move the current column |
| `Mod+Tab` | Return to the previously used workspace |
| `Mod+[` / `Mod+]` | Consume a window into the left / right column, or expel it from the column |
| `Mod+Ctrl+,` / `Mod+.` | Consume from the right / expel the bottom window |
| `Mod+R` / `Mod+Shift+R` | Cycle column-width presets forwards / backwards: 1/3, 1/2, 2/3 |
| `Mod+-` / `Mod+=` | Decrease / increase the column width by 10% |
| `Mod+Shift+-` / `Mod+Shift+=` | Decrease / increase the window height by 10% |
| `Mod+Ctrl+Shift+R` / `Mod+Ctrl+R` | Cycle height presets / restore automatic height |
| `Mod+C` / `Mod+Ctrl+C` | Centre the current column / centre all fully visible columns |
| `Mod+F` / `Mod+Shift+F` | Maximise the column width / fullscreen the window |
| `Mod+M` / `Mod+Ctrl+F` | Maximise the window to the screen edge / expand the column to the remaining width |
| `Mod+V` / `Mod+Shift+V` | Toggle floating / switch focus between floating and tiled |
| `Mod+W` / `Mod+O` | Tabbed column mode / workspace overview |
| `Print` or `Mod+Shift+S` | Interactive screenshot |
| `Ctrl+Print` / `Alt+Print` | Screenshot of the current screen / current window |
| `Mod+Escape` | Toggle application shortcut inhibition, to escape keyboard grabs such as VMs |
| `Mod+Q` / `Mod+Shift+Q` | Close the window / show the session-exit confirmation |

Volume, microphone mute, brightness and media keys are handled by Noctalia and also
work on the lock screen. Screenshots are saved to `~/Pictures/Screenshots/`. Once
the `Alt+Tab` panel is open, use Tab / Shift+Tab or the direction keys to select,
Enter to confirm and Escape to cancel; windows can also be clicked.

## Mouse, touchpad and tablet

- Hold `Mod` and drag the left mouse button to move a window; the right button
  resizes it.
- `Mod+scroll up/down` switches workspaces; with `Ctrl` it moves the current column
  to that workspace.
- `Mod+scroll left/right` or `Mod+Shift+scroll up/down` switches columns; with
  `Ctrl` it moves the column.
- The touchpad has tap-to-click, natural scrolling and disable-while-typing; niri
  provides native three-finger swipe navigation, and a four-finger swipe up opens
  the overview.
- The device workaround that keeps the power key from suspending/powering off is
  preserved. No automatic suspend policy has been added.

New windows take half of the screen by default; a single column is centred
automatically, and switching to a column that does not fit centres it.
The Noctalia settings window uses a floating size relative to the screen. The
internal `DSI-1` output is rotated 270 degrees by default, matching the landscape
keyboard orientation; resolution, refresh rate and scale are still chosen
automatically. Noctalia's overview background layer is integrated with niri; the
actual background effect is chosen in the Noctalia settings.

Thunar with GVfs / UDisks provides file browsing, the trash and access to removable
devices. X11 applications run through xwayland-satellite, which niri starts
automatically. The NixOS niri module provides the GTK file chooser, the GNOME screen
sharing portal, the keyring and XDG autostart.

## Screen orientation

Each stage sets its orientation separately; a single kernel parameter cannot control
the whole boot flow:

| Stage | Configuration | Current behaviour |
| --- | --- | --- |
| systemd-boot menu | `EFI/systemd/drivers/GopRotate_aa64.efi` | Loads the rotation driver used by the former rEFInd setup; the maintainer has verified the landscape menu |
| Linux boot log, TTY | `fbcon=rotate:1` | Clockwise 90-degree landscape, keeping the existing setting |
| Noctalia greeter | `settings.output.transforms = "DSI-1:270"` | The greeter's own compositor rotates the internal output |
| niri desktop, desktop lock screen | `output "DSI-1" { transform "270"; }` | Landscape is applied at startup; no IPC command after login |

niri measures angles counter-clockwise, so 270 degrees matches fbcon's clockwise 90
degrees. The greeter is independent of niri and must be configured separately; this
only matches the internal output and does not fix the orientation of other outputs.
The pen is bound to the internal output through
`input { tablet { map-to-output "DSI-1"; } }`, and its coordinates follow that
output's rotation automatically. Without the binding, niri uses an unrotated
desktop-wide mapping, which can make the pen tip and the cursor differ by a quarter
turn. No extra fixed-rotation calibration matrix is needed.
After applying, check the four corners and the centre with the pen; when temporarily
switching back to portrait, the pen coordinates should follow the output transform
too. First verify whether touch in landscape matches the corners of the picture,
and do not stack a global touch calibration matrix on top in advance.

systemd-boot's `console-mode` selects a text mode offered by the firmware, not a
rotation angle. The landscape menu comes from the GopRotate driver and does not
require reflashing the UEFI. The driver reuses
`BOOT/drivers_aa64/GopRotate_aa64.efi` from the earlier rEFInd boot resources, and
its source revision and hash are pinned in `nixos/boot.nix`. systemd-boot loads the
driver for the matching architecture from `EFI/systemd/drivers/` on the ESP before
showing the menu; keep the `aa64.efi` suffix in the file name, and there is no need
to copy the rEFInd binary or `refind.conf`.

`boot.loader.systemd-boot.extraFiles` is used both by
`nixos-rebuild boot/switch` and by the `esp.img` / `efi-files.zip` packaging of
`nabu-esp`, and covers the rotation driver and the Android boot program. After
deploying, check whether `/boot/efi/EFI/systemd/drivers/GopRotate_aa64.efi` exists,
then reboot and verify the menu, greeter, desktop and display takeover. If a
previously copied driver of the same kind used a different file name, move the old
copy away and keep only this one, so the same driver is not loaded twice.

Reboot after applying and check the greeter and then the desktop; on the desktop run
`niri msg outputs` to inspect DSI-1. An existing user configuration should keep
`include "/etc/niri/config.kdl"` and must not override the internal output's
orientation afterwards. While holding the tablet in portrait you can still run
`niri msg output DSI-1 transform normal`; to restore landscape use
`niri msg output DSI-1 transform 270`. The default is managed through the KDL.

References:
- [niri output configuration](https://niri-wm.github.io/niri/Configuration%3A-Outputs.html)
- [Noctalia Greeter 1.3.1 example configuration](https://github.com/noctalia-dev/noctalia-greeter/blob/v1.3.1/examples/greeter.toml)
- [Linux fbcon rotation](https://docs.kernel.org/fb/fbcon.html)
- [systemd-boot configuration](https://github.com/systemd/systemd/blob/v261/man/loader.conf.xml)

## Applying and validating

On the tablet, apply the configuration from the repository directory:

```sh
sudo nixos-rebuild switch --flake .#nabu
niri validate --config /etc/niri/config.kdl
niri validate
```

Newly added files must be tracked by Git before the Git flake can read them; no
commit is required. `nix flake check --no-build --all-systems` checks the
configuration evaluation for all platforms. Every system build validates the KDL
with the niri on the build machine, so cross builds do not need to run aarch64
programs either. After updating packages or the session environment it is worth
logging in again and then checking screenshots, lock-screen unlock, media keys and
the file chooser.

`~/.config/niri/config.kdl` is an ordinary editable file owned by `nabu`, which
references the system configuration with the following line (niri's keyword is
`include`, not `import`):

```kdl
include "/etc/niri/config.kdl"
```

On the image's first boot, systemd-tmpfiles creates `~/.config` and
`~/.config/niri` (0700) owned by `nabu`, and copies the initial configuration as an
ordinary file (0600). An existing configuration is not overwritten, and the user and
Noctalia can keep adding local settings or theme references after the include. System
configuration updates remain managed by NixOS; on an existing system that lacks this
`include` line, add it manually at the start of the user file.
You can also check the syntax before deploying by running
`niri validate --config nixos/niri.kdl`. KDL validation does not verify how IPC
behaves at runtime; the lock screen, touch input and screen sharing still need
on-device testing.

## References

- [niri 26.04 default configuration](https://github.com/niri-wm/niri/blob/v26.04/resources/default-config.kdl)
- [NixOS Wiki: niri](https://wiki.nixos.org/wiki/Niri)
- [Noctalia v5: niri integration](https://docs.noctalia.dev/noctalia/compositor-settings/niri/)
- [Noctalia v5: IPC commands](https://docs.noctalia.dev/noctalia/ipc/)

This repository keeps its original `Mod+,` settings panel and `Mod+Shift+K` virtual
keyboard bindings, so niri's default consume-window action moved to `Mod+Ctrl+,`
and monitor navigation uses the direction keys.
