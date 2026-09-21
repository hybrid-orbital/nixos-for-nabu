#!/usr/bin/env bash
#
# Capture what happens around a GPU fault on the nabu, without lining up
# timestamps by hand.
#
# The question this answers: which of these removed the mapping the GPU was
# reading from -
#
#   * a per-VA unmap (VM_BIND unmap / shrinker purge / shrinker evict), visible
#     in vm_log() and in msm_iommu_pagetable_unmap(),
#   * a wholesale page table teardown (msm_gem_vm_free() ->
#     msm_iommu_pagetable_destroy()), which logs nothing per VA,
#   * or nothing at all, i.e. the addresses were never mapped by this driver.
#
# It arms a set of kprobes, writes a marker into the kernel log, waits for the
# first `*** gpu fault: ttbr0=...` *after that marker* (faults already in dmesg
# are history and are ignored), snapshots the trace buffer at that moment, keeps
# tracing until a recovery or a grace period, then prints a summary.
#
# Usage (on the tablet):
#
#   sudo bash scripts/nabu-ccu-fault-capture.sh
#
# Run it from a terminal (or over ssh) and then just use the device.  Options:
#
#   --timeout SEC       give up waiting for a fault after SEC seconds (1800)
#   --grace SEC         keep tracing SEC seconds after the first fault (240)
#   --out DIR           output directory (default: mktemp -d /tmp/nabu-ccu-XXXX)
#   --no-package        do not create the tar.gz bundle
#   --analyze-only DIR  re-run the analysis on an existing output directory
#
# To catch the *first* fault of a boot (on this device it happens while the
# Wayland shell comes up, ~90 s in), install nixos/debug/ccu-capture.nix so the
# script is running before the session starts.
#
# See pkgs/kernel/README.md ("Still reproducing on 7.2.6") for the background.

set -euo pipefail

TIMEOUT=1800
GRACE=240
OUT=""
PACKAGE=1
ANALYZE_ONLY=""
PROBES=(vmop ptparams ptmap ptunmap ptdestroy vmfree unusable)

while [[ $# -gt 0 ]]; do
	case "$1" in
	--timeout) TIMEOUT="$2"; shift 2 ;;
	--grace) GRACE="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--no-package) PACKAGE=0; shift ;;
	--analyze-only) ANALYZE_ONLY="$2"; shift 2 ;;
	-h | --help)
		sed -n '2,35p' "$0"
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# ---------------------------------------------------------------- helpers ---

# Strip leading zeros so that dmesg's "0000000101600000" and the trace's
# "101600000" compare equal.
norm_hex() {
	local v="${1#0x}"
	[[ -n "$v" ]] || return 1
	printf '%x' "$((16#$v))"
}

# field <file> <name> -> first value of "name=hexvalue"
field() {
	sed -n "s/.*[^0-9a-f]$2=\([0-9a-fx]*\).*/\1/p" "$1" | head -1
}

# Integer seconds of the first/last event timestamp in a trace file
ts_of() {
	grep -oE '[0-9]+\.[0-9]+: (vmop|ptmap|ptunmap|ptparams|ptdestroy|vmfree|unusable):' "$1" 2>/dev/null |
		grep -oE '^[0-9]+' || true
}

count_in() { # count_in <pattern> <file>
	local n
	n=$(grep -cE "$1" "$2" 2>/dev/null || true)
	printf '%s' "${n:-0}"
}

# Everything the kernel logged after our marker (i.e. new messages).
new_since_marker() {
	local marker="$1" file="$2"
	if grep -qF "$marker" "$file" 2>/dev/null; then
		awk -v m="$marker" 'f{print} index($0,m){f=1}' "$file"
	else
		# No marker (old capture, or the log was rotated): everything is "new".
		cat "$file"
	fi
}

# --------------------------------------------------------------- analysis ---

analysis() {
	local dir="$1"
	local summary="$dir/SUMMARY.txt"
	local fault="$dir/first-fault.txt"
	local trace="$dir/trace-full.txt"
	local before="$dir/trace-before-first-fault.txt"
	local dmesg="$dir/dmesg-full.txt"
	local marker
	marker=$(cat "$dir/marker.txt" 2>/dev/null || echo "")

	{
		echo "=== nabu GPU fault capture ==="
		echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "kernel:   $(cat "$dir/kernel-release.txt" 2>/dev/null || uname -r)"
		echo "out dir:  $dir"
		echo "marker:   ${marker:-<none>}"
		echo
		echo "--- probes ---"
		local e n
		for e in "${PROBES[@]}"; do
			n=$(count_in ": $e:" "$trace")
			printf '  %-10s %s events\n' "$e" "$n"
		done
		if [[ -s "$dir/probe-errors.txt" ]]; then
			echo "  probe errors (could not be armed):"
			sed 's/^/    /' "$dir/probe-errors.txt"
		fi
		echo "  vm op reasons seen in the trace:"
		if grep -qE 'op="' "$trace" 2>/dev/null; then
			grep -oE 'op="[a-z_]*"' "$trace" | sort | uniq -c | sed 's/^/    /'
		else
			echo "    (none - vm_log() is probably inlined, see probe errors)"
		fi
	} >"$summary"

	# Fault history of this boot, which frames the capture.
	{
		echo
		echo "--- GPU faults in this boot ---"
		echo "  total: $(count_in 'gpu fault: ttbr0=' "$dmesg")"
		echo "  per ttbr0:"
		grep -oE 'ttbr0=[0-9a-f]*' "$dmesg" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
		echo "  per iova:"
		grep -oE 'iova=[0-9a-f]*' "$dmesg" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'
		echo "  last faults (t, ttbr0, iova):"
		grep -E 'gpu fault: ttbr0=' "$dmesg" 2>/dev/null | tail -10 |
			sed -n 's/^\[\s*\([0-9.]*\)\].*ttbr0=\([0-9a-f]*\) iova=\([0-9a-f]*\).*/    t=\1 ttbr0=\2 iova=\3/p'
	} >>"$summary"

	if [[ ! -s "$fault" ]]; then
		{
			echo
			echo "--- no new fault captured ---"
			echo "no '*** gpu fault: ttbr0=' line appeared after the marker."
			echo "run it again and reproduce the glitch meanwhile (or use the boot"
			echo "service, nixos/debug/ccu-capture.nix, for the first fault of a boot)."
		} >>"$summary"
		cat "$summary"
		return 0
	fi

	local ttbr iova n_ttbr n_iova fault_ts
	ttbr=$(field "$fault" ttbr0)
	iova=$(field "$fault" iova)
	n_ttbr=$(norm_hex "$ttbr" || true)
	n_iova=$(norm_hex "$iova" || true)
	fault_ts=$(sed -n 's/^\[\s*\([0-9]*\)\..*/\1/p' "$fault" | head -1)

	{
		echo
		echo "--- first new fault ---"
		sed 's/^/  /' "$fault"
		echo "  normalised: ttbr0=$n_ttbr iova=$n_iova (t=$fault_ts s)"

		local first_ts last_ts
		first_ts=$(ts_of "$trace" | head -1)
		last_ts=$(ts_of "$trace" | tail -1)
		echo
		echo "--- trace window ---"
		echo "  trace first/last event: ${first_ts:-?} .. ${last_ts:-?} s"
		if [[ -n "$fault_ts" && -n "$first_ts" && -n "$last_ts" ]]; then
			if awk "BEGIN{exit !($fault_ts >= $first_ts && $fault_ts <= $last_ts)}"; then
				echo "  the trace covered that fault"
			else
				echo "  WARNING: the trace did NOT cover that fault"
			fi
		fi
	} >>"$summary"

	# Answer the question for every faulting iova of this boot, not only the
	# one that happened to be first.
	{
		echo
		echo "--- per-VA events for the faulting iovas ---"
	local iv hits mapped unmapped reasons
		local -a iovas=()
		local v
		# The faulting IOVAs, most frequent first (the recurring ones are the
		# interesting ones).
		while read -r v; do
			[[ -n "$v" ]] || continue
			iovas+=("$(norm_hex "$v" || true)")
		done < <(grep -oE 'iova=[0-9a-f]*' "$dmesg" 2>/dev/null | cut -d= -f2 |
			sort | uniq -c | sort -rn | head -5 | awk '{print $2}')

		for iv in "${iovas[@]}"; do
			[[ -n "$iv" ]] || continue
			hits=$(count_in "(vm|pt)(op|map|unmap):.*iova=$iv " "$trace")
			mapped=$(count_in ": ptmap:.*iova=$iv " "$trace")
			unmapped=$(count_in ": ptunmap:.*iova=$iv " "$trace")
			reasons=$(grep -E "(vm|pt)(op|unmap):.*iova=$iv " "$trace" 2>/dev/null |
				grep -oE 'op="[a-z_]*"' | sort -u | tr '\n' ' ' || true)
			printf '  iova=%-12s events=%-4s ptmap=%-4s ptunmap=%-4s %s\n' \
				"$iv" "$hits" "$mapped" "$unmapped" "$reasons"
		done

		echo
		echo "--- the page table of the captured fault ---"
		local mmu d v
		mmu=$(grep -E ": ptparams:" "$trace" 2>/dev/null |
			grep -E "[^0-9a-f]ttbr=$n_ttbr\b" | tail -1 |
			sed -n 's/.*[^0-9a-f]mmu=\([0-9a-f]*\).*/\1/p' || true)
		if [[ -n "$mmu" ]]; then
			d=$(count_in ": ptdestroy:.*mmu=$mmu" "$before")
			echo "  mmu for ttbr0=$n_ttbr: $mmu"
			printf '  ptmap/ptunmap for it before the fault: %s / %s\n' \
				"$(count_in ": ptmap:.*mmu=$mmu" "$before")" \
				"$(count_in ": ptunmap:.*mmu=$mmu" "$before")"
			echo "  ptdestroy for it before the fault: $d"
			if [[ "$d" != "0" ]]; then
				grep -E ": ptdestroy:.*mmu=$mmu" "$before" | tail -3 | sed 's/^/    /' || true
			fi
		else
			echo "  no ptparams entry for ttbr0=$n_ttbr"
			echo "  (that VM was created before tracing started; use the boot service"
			echo "   to cover it, or rely on the per-iova numbers above)"
		fi
		v=$(count_in ": vmfree:" "$before")
		echo "  msm_gem_vm_free() calls before the fault: $v"

		if [[ -s "$dir/vm-log.txt" ]]; then
			echo "  driver vm-log dump: $(wc -l <"$dir/vm-log.txt") lines (vm-log.txt)"
		else
			echo "  driver vm-log dump: none"
			if [[ "$(cat "$dir/vm-log-shift.txt" 2>/dev/null)" == "0" ]]; then
				echo "    (msm.vm_log_shift=0 - it must be set via boot.kernelParams"
				echo "     so that it is already active when the VM is created)"
			fi
		fi
	} >>"$summary"

	{
		echo
		echo "--- how to read this ---"
		cat <<-'EOF'
		  events > 0 for a faulting iova
		      -> that mapping was removed; op=unmap is a VM_BIND unmap,
		         op=purge/evict the shrinker, op=free/close a teardown.
		  events == 0 but ptdestroy for the fault's mmu > 0
		      -> the whole page table was freed while the GPU was reading
		         (msm_gem_vm_free() -> msm_iommu_pagetable_destroy()), a VM
		         lifetime bug; no per-VA trace can exist for that.
		  events == 0, no ptdestroy, and ptmap == 0 as well
		      -> the address was never mapped by this driver for that VM:
		         suspect the address itself (UBWC / descriptor) or wrong VM.
		EOF
		echo
		echo "send this file plus trace-full.txt (or the tar.gz)."
	} >>"$summary"

	cat "$summary"
}

if [[ -n "$ANALYZE_ONLY" ]]; then
	[[ -d "$ANALYZE_ONLY" ]] || die "--analyze-only needs a directory"
	analysis "$(cd "$ANALYZE_ONLY" && pwd)"
	exit 0
fi

# ----------------------------------------------------------------- tracing ---

if [[ $EUID -ne 0 ]]; then
	die "run as root (tracefs and dmesg need it)"
fi

if [[ -z "$OUT" ]]; then
	OUT=$(mktemp -d /tmp/nabu-ccu-XXXXXX)
else
	mkdir -p "$OUT"
	OUT=$(cd "$OUT" && pwd)
fi
MARKER="nabu-ccu-capture-start-$(date +%s)"
echo "$MARKER" >"$OUT/marker.txt"
uname -r >"$OUT/kernel-release.txt"
{
	uname -a
	echo
	cat /proc/swaps
	echo
	free -m
} >"$OUT/system.txt"
if [[ -r /sys/module/msm/parameters/vm_log_shift ]]; then
	cat /sys/module/msm/parameters/vm_log_shift >"$OUT/vm-log-shift.txt"
else
	echo "unknown" >"$OUT/vm-log-shift.txt"
fi

TRACE=/sys/kernel/tracing
if [[ ! -d "$TRACE" ]]; then
	TRACE=/sys/kernel/debug/tracing
fi
if [[ ! -d "$TRACE" ]]; then
	die "no tracefs (tried /sys/kernel/tracing and /sys/kernel/debug/tracing)"
fi

log "output directory: $OUT"
if [[ "$(cat "$OUT/vm-log-shift.txt")" == "0" ]]; then
	warn "msm.vm_log_shift=0: the driver's own vm-log ring is off, so no 'vm-log:' dump will be printed (kprobes still work)"
fi

echo 0 >"$TRACE/tracing_on"
for e in "${PROBES[@]}"; do
	echo "-:$e" >>"$TRACE/kprobe_events" 2>/dev/null || true
done
: >"$TRACE/trace"
echo 32768 >"$TRACE/buffer_size_kb" 2>/dev/null || true
: >"$OUT/probe-errors.txt"

# vm_log() is static and may be inlined; the others have their address taken in
# the mmu / gpuvm op tables, so they are always probeable.  msm may still be
# loading (boot service), so retry for a while.
arm() {
	local probe="$1" i
	for i in $(seq 1 20); do
		if echo "$probe" >>"$TRACE/kprobe_events" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	if ! echo "$probe" >>"$TRACE/kprobe_events" 2>>"$OUT/probe-errors.txt"; then
		warn "could not arm probe: $probe"
	fi
}

arm 'p:vmop vm_log vm=%x0 op=+0(%x1):string iova=%x2 range=%x3 qid=%x4'
arm 'r:ptparams msm_iommu_pagetable_params mmu=$arg1 ttbr=+0($arg2):u64 asid=+0($arg3):s32'
arm 'p:ptmap msm_iommu_pagetable_map mmu=%x0 iova=%x1 len=%x2'
arm 'p:ptunmap msm_iommu_pagetable_unmap mmu=%x0 iova=%x1 len=%x2'
arm 'p:ptdestroy msm_iommu_pagetable_destroy mmu=%x0'
arm 'p:vmfree msm_gem_vm_free gpuvm=%x0'
arm 'p:unusable msm_gem_vm_unusable gpuvm=%x0'

for e in "${PROBES[@]}"; do
	if [[ -e "$TRACE/events/kprobes/$e/enable" ]]; then
		echo 1 >"$TRACE/events/kprobes/$e/enable"
	fi
done
: >"$TRACE/trace"
echo 1 >"$TRACE/tracing_on"
log "tracing armed ($(grep -c . "$TRACE/kprobe_events" 2>/dev/null || echo 0) probes), marker $MARKER"

# The marker goes into the kernel log *before* we start collecting it, so that
# everything dmesg replays from its ring buffer can be recognised as history.
if [[ -w /dev/kmsg ]]; then
	echo "$MARKER: tracing armed" >/dev/kmsg || warn "could not write the marker to /dev/kmsg"
else
	warn "/dev/kmsg is not writable; falling back to 'everything in the buffer is new'"
fi

dmesg -w >"$OUT/kmsg-live.txt" 2>/dev/null &
DMESG_PID=$!
cleanup() {
	echo 0 >"$TRACE/tracing_on" 2>/dev/null || true
	kill "$DMESG_PID" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT

log ">>> reproduce now (just use the device); waiting for a new GPU fault"
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
	if new_since_marker "$MARKER" "$OUT/kmsg-live.txt" | grep -q -m1 'gpu fault: ttbr0='; then
		break
	fi
	if (($(date +%s) > deadline)); then
		warn "no new GPU fault within ${TIMEOUT}s"
		break
	fi
	sleep 1
done

if new_since_marker "$MARKER" "$OUT/kmsg-live.txt" | grep -q -m1 'gpu fault: ttbr0='; then
	new_since_marker "$MARKER" "$OUT/kmsg-live.txt" |
		grep -m5 -E 'gpu fault: ttbr0=|gpu fault ring|hangcheck recover|offending task' >"$OUT/first-fault.txt"
	cp "$OUT/kmsg-live.txt" "$OUT/kmsg-at-first-fault.txt"

	# Snapshot everything up to (and including) the first new fault.
	echo 0 >"$TRACE/tracing_on"
	cat "$TRACE/trace" >"$OUT/trace-before-first-fault.txt"
	echo 1 >"$TRACE/tracing_on"
	log "NEW FAULT: $(head -1 "$OUT/first-fault.txt")"
	log "still tracing for up to ${GRACE}s to catch the recovery and the vm-log dump"

	deadline=$(( $(date +%s) + GRACE ))
	while :; do
		if new_since_marker "$MARKER" "$OUT/kmsg-live.txt" |
			awk '/gpu fault: ttbr0=/{seen=1} seen && /hangcheck recover/{found=1} END{exit !found}'; then
			break
		fi
		if (($(date +%s) > deadline)); then
			break
		fi
		sleep 2
	done
	sleep 5
fi

echo 0 >"$TRACE/tracing_on"
cat "$TRACE/trace" >"$OUT/trace-full.txt"
dmesg >"$OUT/dmesg-full.txt" 2>/dev/null || true
cp "$OUT/kmsg-live.txt" "$OUT/kmsg-live-final.txt" 2>/dev/null || true
grep -n -A300 'vm-log:' "$OUT/dmesg-full.txt" >"$OUT/vm-log.txt" 2>/dev/null || true

kill "$DMESG_PID" 2>/dev/null || true
trap - EXIT

log "analysis"
analysis "$OUT"

if [[ $PACKAGE -eq 1 ]]; then
	tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
	log "bundle: $OUT.tar.gz"
fi
log "done"
