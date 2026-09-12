**English** | [简体中文](zh_CN/usage-on-device.md)

# On-device updates, rollback and cleanup

[Back to project home](../README.md)

Boot files and the generation menu are currently managed by the native NixOS
systemd-boot installer. No UKI deployment hook runs any more, and there is no
`nabu-previous.efi` backup mechanism.

## Preparing a configuration

Keep a checkout of the repository on the tablet and start modifying from the commit
or release you want to use:

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
git checkout v0.1.0-alpha
# create your own branch when you want to keep modifying
git switch -c my-nabu
```

Setting the flake registry and NIX_PATH automatically is disabled, so use
`--flake` explicitly. New files must be tracked by Git before the Git flake can
read them; a commit is not required. The first native rebuild after starting from a
cross-built image may rebuild a large number of dependencies; see the
[build guide](building.md).

## Routine updates

The ext4 system's host name is `nabu` (an alias of `ext4-nabu`) and the impermanent
one is `impermanent-nabu`, so the command below automatically selects the
configuration of the installed storage profile without writing `#hostname` by hand:

```sh
sudo nixos-rebuild switch --flake .
```

It builds the system closure, updates the system profile, installs the boot entries
and activates the running configuration. Kernel and initrd changes take effect on
the next boot. To prepare only the next boot without switching the running services:

```sh
sudo nixos-rebuild boot --flake .
```

To test a userspace-only configuration temporarily, use
`nixos-rebuild test --flake .`; it does not make the test result the default system
for the next boot, and it cannot change the running kernel. See the
[desktop notes](desktop.md#applying-and-validating) for how desktop
configuration updates relate to writable user configuration.

When you want to update nixpkgs, run `nix flake update` deliberately first and then
build and validate. An ordinary rebuild does not automatically update locked inputs
to their latest versions. Keep a bootable older generation, especially before
changing the kernel, initrd, graphics or power settings.

## Rollback

While the system is still usable:

```sh
sudo nixos-rebuild switch --rollback
```

If you only want to schedule the older generation for the next boot without
switching the running services, use `sudo nixos-rebuild boot --rollback`. After
rebooting, check the actual boot entry and kernel. Do not use a plain Nix profile
change as a substitute for boot-loader deployment.

When a new configuration does not boot, select a retained older generation in the
systemd-boot menu. That entry selects the matching kernel, initrd, DTB and specific
system closure, rather than "old kernel plus current profile". Booting an older
generation from the menu by hand does not mean the system profile has been changed
permanently; after booting, inspect the generations and then either roll back or fix
the configuration and rebuild. Do not assume `--rollback` always points at the entry
you just selected manually.

```sh
sudo nix-env -p /nix/var/nix/profiles/system --list-generations
readlink -f /run/current-system
readlink -f /run/booted-system
readlink -f /nix/var/nix/profiles/system
bootctl list
```

`/run/current-system`, `/run/booted-system` and the default system profile may
differ after a `switch` or after selecting an older generation by hand; that alone
is not an error. A generation does not restore user files, database contents or disk
partitions.

## ESP space and cleaning up history

Identical boot files can be shared, but different kernels, initrds and DTBs still
need space. The repository does not currently set an explicit generation limit; you
can add this to your own configuration:

```nix
boot.loader.systemd-boot.configurationLimit = 10;
```

This option limits the number of generations kept in the boot menu and is not
equivalent to deleting historical systems from the Nix store. Deleting old
generations and running GC reduces what you can roll back to; first confirm which
versions you want to keep.

```sh
# Example: after you are sure that generations older than 30 days are no longer needed
sudo nix-collect-garbage --delete-older-than 30d
# redeploy the menu so that it matches the retained system generations
sudo nixos-rebuild boot --flake .
df -h / /boot/efi
```

The initial image's `/nixos/*` and `nixos-nabu.conf`, as well as old rEFInd/UKI
files, are not necessarily covered by later nixpkgs installer cleanup. Do not delete
files first and then see whether it still boots; check the references in all
retained menu entries first.

## Power and failures

logind currently ignores the power key and niri also disables its built-in power-key
handling. The system can enter s2idle again (the Bluetooth UART immediate-wake bug
is fixed), but an unresponsive key does not suspend the system: do not mistake an
unresponsive key for a normal suspend, and do not equate locking the screen with
screen-off or suspend. Occasional boot failures are still a known issue; see
[device status](device-status.md) and
[boot diagnostics](boot-logging.md) for how to report them.
