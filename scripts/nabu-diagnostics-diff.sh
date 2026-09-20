#!/usr/bin/env bash
# Compare two bundles collected by scripts/nabu-diagnostics.sh and print the
# differences that matter when investigating nabu kernel behaviour:
#
#   * which clocks/regulators/power domains are active in one kernel only
#   * which devices are not runtime-suspended (idle power)
#   * cpuidle state usage, thermal zones, interrupt (wakeup) rates
#   * display, USB/typec and power-supply state
#   * the pstore records, i.e. what a boot that died or stalled left behind
#
# Usage: bash scripts/nabu-diagnostics-diff.sh BUNDLE-A BUNDLE-B
#
# A is normally the known-good sm8150-fork boot, B the mainline-latest boot.
# Run both collections under comparable conditions (same workload, same
# charger state, WiFi on/off the same way).
set -uo pipefail
export LC_ALL=C

have() { command -v "$1" >/dev/null 2>&1; }

if [[ $# -ne 2 ]]; then
  echo "usage: $0 BUNDLE-A BUNDLE-B" >&2
  exit 1
fi
a=${1%/}
b=${2%/}
for d in "$a" "$b"; do
  [[ -d $d ]] || { echo "not a directory: $d" >&2; exit 1; }
done

limit=${NABU_DIAG_DIFF_LIMIT:-30}
tmpd=${TMPDIR:-/tmp}
section() { printf '\n=== %s %s\n' "$1" "${2:+($2)}"; }
sub() { printf '\n--- %s\n' "$1"; }

# show_diff <fileA> <fileB>: print the differing lines of two text files, or
# "no difference" when there is nothing to show.
show_diff() {
  local out
  out=$(diff "$1" "$2" 2>/dev/null | grep -E '^[<>]' |
    sed 's/^</  A:/; s/^>/  B:/' | head -"$limit")
  if [[ -z $out ]]; then echo "  no difference"; else printf '%s\n' "$out"; fi
}

headline() {
  for d in "$a" "$b"; do
    printf '%-28s %s\n' "$(basename "$d")" "$(cat "$d/meta/uname.txt" 2>/dev/null | cut -c1-100)"
    printf '%-28s %s\n' "  cmdline" "$(cat "$d/meta/cmdline.txt" 2>/dev/null | cut -c1-100)"
    printf '%-28s %s\n' "  kernel" \
      "$(sed -n 's/.*current-system\/kernel -> //p' "$d/meta/kernel-links.txt" 2>/dev/null)"
    printf '%-28s %s\n' "  generation" "$(tail -1 "$d/meta/generation.txt" 2>/dev/null | cut -c1-100)"
  done
  if [[ -r $a/meta/fdt.dtb && -r $b/meta/fdt.dtb ]]; then
    if cmp -s "$a/meta/fdt.dtb" "$b/meta/fdt.dtb"; then
      echo "device tree: identical in both boots"
    else
      echo "device tree: DIFFERENT (decompile with dtc -I dtb -O dts to see how)"
    fi
  fi
}

# Print "name field" pairs parsed out of a file, keeping only lines whose
# numeric field is greater than zero (clk_summary/regulator_summary layouts).
nonzero() { # nonzero <file> <numeric column>
  [[ -r $1 ]] || return 0
  awk -v col="$2" '
    $1 !~ /^-+$/ && $1 != "clock" && $1 != "regulator" && NF > col {
      v = $(col); if (v ~ /^[0-9]+$/ && v > 0) print $1
    }' "$1" | LC_ALL=C sort -u
}

compare_sets() { # compare_sets <label> <fileA> <fileB> <numeric column> <explain>
  local label=$1 fa=$2 fb=$3 col=$4 explain=$5
  local onlya onlyb
  onlya=$(comm -23 <(nonzero "$fa" "$col") <(nonzero "$fb" "$col"))
  onlyb=$(comm -13 <(nonzero "$fa" "$col") <(nonzero "$fb" "$col"))
  sub "$label: $explain"
  if [[ -z $onlya && -z $onlyb ]]; then
    echo "  no difference"
    return
  fi
  [[ -n $onlya ]] && { echo "  active in A only ($(wc -l <<<"$onlya" | tr -d ' ')):"; sed "s/^/    /" <<<"$onlya" | head -"$limit"; }
  [[ -n $onlyb ]] && { echo "  active in B only ($(wc -l <<<"$onlyb" | tr -d ' ')):"; sed "s/^/    /" <<<"$onlyb" | head -"$limit"; }
}

headline

section "power: what stays enabled" "the usual explanation for an idle-power delta"
compare_sets "clocks" "$a/clocks/clk_summary.txt" "$b/clocks/clk_summary.txt" 2 \
  "enable_count > 0 in one boot only"
compare_sets "regulators" "$a/clocks/regulator_summary.txt" "$b/clocks/regulator_summary.txt" 2 \
  "use count > 0 in one boot only"

sub "power domains (pm_genpd_summary): status differs"
if [[ -r $a/clocks/pm_genpd_summary.txt && -r $b/clocks/pm_genpd_summary.txt ]]; then
  awk '/^[A-Za-z0-9_.-]+[ \t]+(on|off)[ \t]/ { print $1, $2 }' \
    "$a/clocks/pm_genpd_summary.txt" | LC_ALL=C sort -u >"$tmpd/nabu-genpd-a.$$"
  awk '/^[A-Za-z0-9_.-]+[ \t]+(on|off)[ \t]/ { print $1, $2 }' \
    "$b/clocks/pm_genpd_summary.txt" | LC_ALL=C sort -u >"$tmpd/nabu-genpd-b.$$"
  show_diff "$tmpd/nabu-genpd-a.$$" "$tmpd/nabu-genpd-b.$$"
  rm -f "$tmpd/nabu-genpd-a.$$" "$tmpd/nabu-genpd-b.$$"
else
  echo "  one of the bundles has no pm_genpd_summary"
fi

sub "runtime PM: devices not suspended in one boot only"
if [[ -r $a/clocks/runtime_pm.txt && -r $b/clocks/runtime_pm.txt ]]; then
  awk '$1 != "suspended" { print $3 }' "$a/clocks/runtime_pm.txt" | LC_ALL=C sort -u >"$tmpd/nabu-awake-a.$$"
  awk '$1 != "suspended" { print $3 }' "$b/clocks/runtime_pm.txt" | LC_ALL=C sort -u >"$tmpd/nabu-awake-b.$$"
  onlya=$(comm -23 "$tmpd/nabu-awake-a.$$" "$tmpd/nabu-awake-b.$$")
  onlyb=$(comm -13 "$tmpd/nabu-awake-a.$$" "$tmpd/nabu-awake-b.$$")
  rm -f "$tmpd/nabu-awake-a.$$" "$tmpd/nabu-awake-b.$$"
  if [[ -z $onlya && -z $onlyb ]]; then
    echo "  no difference"
  else
    [[ -n $onlya ]] && { echo "  awake in A only:"; sed 's/^/    /' <<<"$onlya" | head -"$limit"; }
    [[ -n $onlyb ]] && { echo "  awake in B only:"; sed 's/^/    /' <<<"$onlyb" | head -"$limit"; }
  fi
else
  echo "  one of the bundles has no runtime_pm.txt"
fi

section "idle behaviour"
sub "cpuidle: usage/time per cpu and state (A = first bundle, B = second)"
if [[ -r $a/idle/cpuidle.txt && -r $b/idle/cpuidle.txt ]]; then
  awk '
    function field(prefix,   i) {
      for (i = 4; i <= NF; i++) if (index($i, prefix) == 1) return substr($i, length(prefix) + 1)
      return "-"
    }
    FNR == NR {
      key = $1 " " $2 " " $3
      au[key] = field("usage="); at[key] = field("time="); order[key] = 1
      next
    }
    {
      key = $1 " " $2 " " $3
      printf "  %-26s A usage=%-10s time=%-14s | B usage=%-10s time=%-14s\n",
             key, (key in au ? au[key] : "-"), (key in at ? at[key] : "-"),
             field("usage="), field("time=")
      seen[key] = 1
    }
    END {
      for (k in order)
        if (!(k in seen))
          printf "  %-26s A usage=%-10s time=%-14s | B absent\n", k, au[k], at[k]
    }
  ' "$a/idle/cpuidle.txt" "$b/idle/cpuidle.txt" | LC_ALL=C sort -k2,2 | head -"$limit"
  echo "  (higher usage/time = that state is entered more / slept in longer)"
else
  echo "  one of the bundles has no cpuidle.txt"
fi

sub "thermal zones"
if [[ -r $a/idle/thermal.txt && -r $b/idle/thermal.txt ]]; then
  paste <(LC_ALL=C sort "$a/idle/thermal.txt") <(LC_ALL=C sort "$b/idle/thermal.txt") |
    awk -F'\t' '{ printf "  A: %-42s B: %s\n", $1, $2 }' | head -"$limit"
else
  echo "  one of the bundles has no thermal.txt"
fi

section "wakeup sources" "top interrupt deltas for the same 30 s window"
for d in "$a" "$b"; do
  sub "$(basename "$d")"
  if [[ -r $d/irq/interrupts-delta.txt ]]; then
    head -12 "$d/irq/interrupts-delta.txt" | sed 's/^/  /'
  else
    echo "  no interrupt delta collected"
  fi
done

section "USB / typec" "OTG and role switching"
for f in typec.txt devices.txt; do
  [[ -r $a/usb/$f && -r $b/usb/$f ]] || continue
  sub "$f (only in one boot)"
  show_diff "$a/usb/$f" "$b/usb/$f"
done

section "display"
if [[ -r $a/display/drm.txt && -r $b/display/drm.txt ]]; then
  show_diff "$a/display/drm.txt" "$b/display/drm.txt"
else
  echo "  one of the bundles has no drm.txt"
fi

section "power supplies" "charger / USB-C port state"
if [[ -r $a/power/power_supply.txt && -r $b/power/power_supply.txt ]]; then
  show_diff "$a/power/power_supply.txt" "$b/power/power_supply.txt"
else
  echo "  one of the bundles has no power_supply.txt"
fi

section "pstore" "what a failed or stalled boot left behind"
for d in "$a" "$b"; do
  sub "$(basename "$d")"
  if compgen -G "$d/pstore/*" >/dev/null; then
    ls -l "$d/pstore" | tail -n +2 | sed 's/^/  /'
    newest=$(ls -t "$d/pstore"/console-ramoops* "$d/pstore"/dmesg-ramoops* 2>/dev/null | head -1)
    if [[ -n ${newest:-} ]]; then
      echo "  --- first 40 lines of $(basename "$newest")"
      head -40 "$newest" | sed 's/^/  /'
    fi
  else
    echo "  no records"
  fi
done

section "deferred probes" "devices still waiting for a driver/provider"
for d in "$a" "$b"; do
  sub "$(basename "$d")"
  if [[ -s $d/misc/devices_deferred.txt ]]; then
    head -"$limit" "$d/misc/devices_deferred.txt" | sed 's/^/  /'
  else
    echo "  none"
  fi
done

section "errors while collecting"
for d in "$a" "$b"; do
  sub "$(basename "$d")"
  if [[ -s $d/misc/errors.txt ]]; then
    sed 's/^/  /' "$d/misc/errors.txt" | head -10
  else
    echo "  none"
  fi
done
