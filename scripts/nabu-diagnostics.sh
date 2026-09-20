#!/usr/bin/env bash
# Collect kernel and hardware diagnostics from a running Xiaomi Pad 5 into one
# directory, so that two boots (for example the pinned sm8150-fork kernel and
# mainline-latest) can be compared with scripts/nabu-diagnostics-diff.sh.
#
# Usage: sudo bash scripts/nabu-diagnostics.sh [OUTPUT_PARENT]
#
# The bundle is written to OUTPUT_PARENT/nabu-diag-<host>-<release>-<utc>/ and
# nothing outside it is touched: the script only reads /proc, /sys and debugfs.
# Run it as root — clocks, power domains, regulators, pstore and the USB/typec
# state are root-only.
#
# Collected (see docs/boot-logging.md for what to look at):
#   meta/     kernel, cmdline, model, running generation, live DTB
#   pstore/   records of the *previous* boot, i.e. a crash or a hang
#   clocks/   clk_summary, pm_genpd_summary, regulator_summary, runtime PM
#   idle/     cpuidle state usage/time, cpufreq, thermal zones
#   irq/      two /proc/interrupts snapshots 30 s apart plus their delta
#   usb/      typec port state, USB device tree, per-device runtime PM
#   display/  DRM connector state and modes, panel power state
#   power/    power_supply properties (including the USB-C port)
#   misc/     modules, remoteprocs, deferred probes, dmesg, journal
set -uo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "run as root: sudo bash $0 [OUTPUT_PARENT]" >&2
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

parent=${1:-$PWD}
host=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo nabu)
release=$(uname -r)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$parent/nabu-diag-$host-$release-$stamp"

mkdir -p "$out"/{meta,pstore,clocks,idle,irq,usb,display,power,misc}
errors="$out/misc/errors.txt"
: > "$errors"

note() { echo "$*" >> "$errors"; }

save() { # save <relative file> <command...>
  local f="$out/$1"
  shift
  "$@" >"$f" 2>/dev/null || note "collector failed: $*"
}

savefile() { # savefile <relative file> <path to read>
  local f="$out/$1" src="$2"
  if [[ -r $src ]]; then
    cat "$src" >"$f" 2>/dev/null || note "unreadable: $src"
  else
    note "missing: $src"
  fi
}

echo "collecting into $out"

# == meta ====================================================================
save meta/uname.txt uname -a
savefile meta/version.txt /proc/version
savefile meta/cmdline.txt /proc/cmdline
savefile meta/os-release.txt /etc/os-release
save meta/model.txt sh -c "tr -d '\\0' < /proc/device-tree/model"
save meta/generation.txt sh -c "nixos-rebuild list-generations 2>/dev/null | tail -5"
save meta/kernel-links.txt sh -c "
  for l in /run/current-system/kernel /run/booted-system/kernel; do
    printf '%s -> %s\n' \"\$l\" \"\$(readlink -f \$l 2>/dev/null)\"
  done"
if [[ -r /sys/firmware/fdt ]]; then
  cp /sys/firmware/fdt "$out/meta/fdt.dtb" 2>/dev/null ||
    note "could not copy /sys/firmware/fdt"
fi

# == pstore: the previous boot's log =========================================
if compgen -G "/sys/fs/pstore/*" >/dev/null; then
  cp -a /sys/fs/pstore/. "$out/pstore/" 2>/dev/null || note "could not copy /sys/fs/pstore"
else
  note "no pstore records (previous boot left none)"
fi

# == debugfs: mount it if systemd did not ====================================
debugfs=/sys/kernel/debug
if [[ ! -d $debugfs/clk ]] && have mountpoint && ! mountpoint -q "$debugfs"; then
  mount -t debugfs debugfs "$debugfs" 2>/dev/null || note "could not mount debugfs"
fi

# == clocks, power domains, regulators, runtime PM ===========================
savefile clocks/clk_summary.txt "$debugfs/clk/clk_summary"
savefile clocks/pm_genpd_summary.txt "$debugfs/pm_genpd/pm_genpd_summary"
savefile clocks/regulator_summary.txt "$debugfs/regulator/regulator_summary"
savefile misc/devices_deferred.txt "$debugfs/devices_deferred"
save misc/debugfs-listing.txt sh -c "ls -1 $debugfs"

{
  for d in /sys/bus/*/devices/*/power; do
    [[ -r $d/runtime_status ]] || continue
    printf '%-10s %-10s %s\n' \
      "$(cat "$d/runtime_status" 2>/dev/null)" \
      "$(cat "$d/control" 2>/dev/null)" \
      "${d#/sys/bus/}"  # drop the /sys/bus/ prefix to keep the report readable
  done
} 2>/dev/null | LC_ALL=C sort -k3 >"$out/clocks/runtime_pm.txt"

# == idle, cpufreq, thermal ==================================================
{
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    for st in "$cpu"/cpuidle/state[0-9]*; do
      [[ -r $st/name ]] || continue
      printf '%s state%s %-12s usage=%-12s time=%-14s disable=%s\n' \
        "$(basename "$cpu")" "${st##*state}" \
        "$(cat "$st/name" 2>/dev/null)" \
        "$(cat "$st/usage" 2>/dev/null)" \
        "$(cat "$st/time" 2>/dev/null)" \
        "$(cat "$st/disable" 2>/dev/null)"
    done
  done
} >"$out/idle/cpuidle.txt" 2>/dev/null

{
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    cd="$cpu/cpufreq"
    [[ -r $cd/scaling_cur_freq ]] || continue
    printf '%s governor=%-12s cur=%-9s policy-min=%-9s policy-max=%s\n' \
      "$(basename "$cpu")" \
      "$(cat "$cd/scaling_governor" 2>/dev/null)" \
      "$(cat "$cd/scaling_cur_freq" 2>/dev/null)" \
      "$(cat "$cd/scaling_min_freq" 2>/dev/null)" \
      "$(cat "$cd/scaling_max_freq" 2>/dev/null)"
  done
  echo
  for f in /sys/devices/system/cpu/cpufreq/policy*/stats/time_in_state; do
    [[ -r $f ]] || continue
    echo "== $f"
    cat "$f"
  done
} >"$out/idle/cpufreq.txt" 2>/dev/null

{
  for z in /sys/class/thermal/thermal_zone*; do
    [[ -r $z/type ]] || continue
    printf '%-24s %s\n' "$(basename "$z") $(cat "$z/type")" "$(cat "$z/temp" 2>/dev/null)"
  done
} >"$out/idle/thermal.txt" 2>/dev/null

# == interrupts: rate snapshot ===============================================
save irq/interrupts-0.txt cat /proc/interrupts
sleep ${NABU_DIAG_IRQ_INTERVAL:-30}
save irq/interrupts-1.txt cat /proc/interrupts
if have awk; then
  awk '
    FNR == NR {
      if ($1 ~ /^[0-9]+:$/) { s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i
                              base[$1] = s; label[$1] = $NF }
      next
    }
    $1 ~ /^[0-9]+:$/ {
      s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i
      d = s - base[$1]
      if (d > 0) printf "%9d  %-20s %s\n", d, label[$1], $1
    }
  ' "$out/irq/interrupts-0.txt" "$out/irq/interrupts-1.txt" 2>/dev/null |
    LC_ALL=C sort -rn >"$out/irq/interrupts-delta.txt" ||
    note "could not compute interrupt deltas"
else
  note "awk missing: no interrupt delta"
fi

# == USB / typec =============================================================
savefile usb/usb-devices.txt "$debugfs/usb/devices"
{
  for p in /sys/class/typec/*; do
    [[ -e $p ]] || continue
    echo "== $(basename "$p")"
    for f in data_role power_role port_type svid vconn_source \
      usb_power_delivery_revision; do
      [[ -r $p/$f ]] && printf '%-28s %s\n' "$f:" "$(cat "$p/$f" 2>/dev/null)"
    done
  done
} >"$out/usb/typec.txt" 2>/dev/null
{
  for d in /sys/bus/usb/devices/*; do
    [[ -r $d/idVendor ]] || continue
    printf '%-14s %s:%s %-28s %s\n' "$(basename "$d")" \
      "$(cat "$d/idVendor" 2>/dev/null)" "$(cat "$d/idProduct" 2>/dev/null)" \
      "$(cat "$d/product" 2>/dev/null)" "$(cat "$d/speed" 2>/dev/null)"
  done
} >"$out/usb/devices.txt" 2>/dev/null

# == display =================================================================
{
  for c in /sys/class/drm/*; do
    [[ -e $c/status ]] || continue
    echo "== $(basename "$c")"
    for f in status enabled dpms modes; do
      [[ -r $c/$f ]] && printf '%-16s %s\n' "$f:" "$(tr '\n' ' ' <"$c/$f" 2>/dev/null)"
    done
    [[ -r $c/device/power/runtime_status ]] &&
      printf '%-16s %s\n' "runtime_status:" "$(cat "$c/device/power/runtime_status")"
  done
  echo
  ls -1 "$debugfs/dri" 2>/dev/null
} >"$out/display/drm.txt" 2>/dev/null

# == power supplies ==========================================================
{
  for ps in /sys/class/power_supply/*; do
    [[ -e $ps ]] || continue
    echo "== $(basename "$ps")"
    for f in status capacity current_now voltage_now online usb_type charge_type \
      charge_control_limit health; do
      [[ -r $ps/$f ]] && printf '%-22s %s\n' "$f:" "$(cat "$ps/$f" 2>/dev/null)"
    done
  done
} >"$out/power/power_supply.txt" 2>/dev/null

# == miscellaneous ===========================================================
savefile misc/modules.txt /proc/modules
savefile misc/mem_sleep.txt /sys/power/mem_sleep
save misc/kernel-log.txt dmesg
save misc/kernel-log-errors.txt sh -c "dmesg --level=err,warn"
if have journalctl; then
  save misc/journal-kernel.txt journalctl -b -k --no-pager -o short-monotonic
fi
{
  for r in /sys/class/remoteproc/*; do
    [[ -e $r ]] || continue
    echo "== $(basename "$r")"
    for f in name state firmware; do
      [[ -r $r/$f ]] && printf '%-10s %s\n' "$f:" "$(cat "$r/$f" 2>/dev/null)"
    done
  done
} >"$out/misc/remoteproc.txt" 2>/dev/null

du -sh "$out" 2>/dev/null
echo
echo "done. copy the directory somewhere and compare two runs with"
echo "  bash scripts/nabu-diagnostics-diff.sh <bundle-A> <bundle-B>"
if [[ -s $errors ]]; then
  echo
  echo "note: some collectors reported problems, see misc/errors.txt:"
  sed 's/^/  /' "$errors" | head -10
fi
