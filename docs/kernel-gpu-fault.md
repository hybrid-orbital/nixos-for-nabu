# GPU faults on `mainline-latest` (SM8150 / nabu) — investigation report

Status: **open**.  The device sometimes produces SMMU translation faults from the
GPU, and the driver reacts with a GPU reset ("hangcheck recover"), which the
user sees as the screen glitching, occasionally going black and then redrawing.
`sm8150-fork` (6.17) does not reproduce it, which is why it is still the
default kernel.

**Source audit update (2026-09-21):** §12 identifies a concrete A640/A680
GBIF initialization omission and provides an opt-in, build-tested patch.
Its connection to the observed CCU faults is **not yet hardware-confirmed**.
The original captures do not establish that the faulting address was previously
unmapped: the analyzer matches starting addresses rather than intervals, and
some older `ptmap` probes recorded the SG pointer as `len`. See §12 before
using the exclusion table as proof of a root cause.

This document is written for somebody who will work on the kernel side.  It
records what was measured, what was ruled out and how, the code paths that can
remove a GPU VA mapping, and the instrumentation that should be added next.  It
deliberately separates *measured* facts from *inferred* ones.

中文要点：GPU（CCU）会去读没有有效 PTE 的 VA，每次"第一次 fault"都会触发一次 GPU
recovery。已排除：用户态 VM_BIND 管理、GEM shrinker 回收、页表整体销毁、UBWC 地址
计算、以及 fence/拆映射代码差异（与不复现的 6.17 fork 逐字相同）。剩下最可能的解释
是"内核在 BO 的 fence 之后拆掉 VA，而硬件仍有对该 VA 的读取"，但这是原调查的推测，
现有 trace 尚不能证实。后续源码审计发现 A640/A680 的 GBIF 初始化漏配，并提供了
已编译通过的候选补丁及 A/B 步骤（第 12 节）；是否修复本次 fault 仍需真机验证。

## 1. Environment

| | |
| --- | --- |
| Device | Xiaomi Pad 5 (nabu), SM8150, Adreno 640 (a640), 2560x1600 dual-DSI panel |
| Kernel | mainline `7.2.6` from nixpkgs `linux_latest` (flake input `20b1ddd1`, 2026-09-19), nixpkgs common config + `pkgs/kernel/mainline-latest/configs/` |
| Patches | `pkgs/kernel/mainline-latest/patches/` — device tree, panel, touchscreen, sound, charging, runtime fixes, plus `0008` (re-apply upstream's bonded-DSI PLL fix that 7.2.6 reverts) |
| Userspace | NixOS with niri (Wayland) + noctalia (shell), Firefox 156 (WebRender on freedreno GL, `GL_RENDERER FD640`), Mesa from the same nixpkgs |
| Working reference | `sm8150-fork` = sm8150-mainline `v6.17.0-sm8150`, no faults observed |

Reproduction: boot `mainline-latest`, use the machine normally.  Faults appear
within ~1 minute at shell startup and then in bursts while any GL client runs;
Firefox triggers them most reliably.

## 2. Observed behaviour

```
[  443.548243] *** gpu fault: ttbr0=000000014533e000 iova=0000000101600000 dir=READ type=TRANSLATION source=CCU (0,0,0,1)
[  443.560162] *** gpu fault: ttbr0=000000014533e000 iova=0000000101600000 dir=READ type=TRANSLATION source=CCU (0,0,0,1)
...
[  448.524908] adreno_fault_handler: 39 callbacks suppressed
...
[  587.429416] adreno 2c00000.gpu: [drm:a6xx_irq [msm]] *ERROR* gpu fault ring 0 fence d1a9 status 00800005 rb 04a0/0505 ib1 000000010062D000/001f ib2 000000010063DA00/0000
[  587.430085] msm_dpu ae01000.display-controller: [drm:recover_worker [msm]] *ERROR* 06040001: hangcheck recover!
[  587.430252] msm_dpu ae01000.display-controller: [drm:recover_worker [msm]] *ERROR* 06040001: offending task: firefox:gdrv0 (.../firefox-156.0/bin/firefox)
```

## 3. Anatomy of a fault (log → code)

* `*** gpu fault:` is printed by `adreno_fault_handler()`
  (`drivers/gpu/drm/msm/adreno/adreno_gpu.c`).
  * `type=TRANSLATION` ← `info->fsr & ARM_SMMU_FSR_TF`: the SMMU walk found **no
    valid PTE** for that IOVA (`PERMISSION`/`EXTERNAL` are the other options).
  * `dir=READ`, and `source=` is the GPU block that issued the transaction:
    `a6xx_fault_block(gpu, info->fsynr1 & 0xff)` (`adreno/a6xx_gpu.c`) maps
    `0 → CP`, `4 → CCU`, `6 → CDP Prefetch`, `7 → GMU`, `5 → flag cache`
    (a7xx), everything else → the UCHE client decode.
  * The trailing `(0,0,0,1)` are `CP_SCRATCH4..7`.
* After the first fault the handler *disables* stall-on-fault
  (`priv->stall_enabled = false; mmu->funcs->set_stall(mmu, false)`) and
  re-arms it 500 ms later (`adreno_check_and_reenable_stall()`).  The long
  storms with `N callbacks suppressed` are therefore by design.
* The reset comes from `a6xx_fault_detect_irq()` (RBBM fault detect,
  `status 00800005`): it prints the `gpu fault ring …` line, deletes the
  hangcheck timer and queues `recover_work`, which prints `hangcheck recover!`
  and `offending task:`.
* In the recovery path, VM_BIND contexts are additionally poisoned:
  `if (!vm->managed) msm_gem_vm_unusable(submit->vm);` (`msm_gpu.c` ~500) —
  "faults mark the VM as unusable, matching Vulkan expectations".  So for such
  a VM **the first fault is the root cause and every later fault in it is
  fallout**.

## 4. Measured data

Tool: `scripts/nabu-ccu-fault-capture.sh` (kprobes + tracefs, see §8); bundles
under `/var/lib/nabu-ccu/`.  Two representative captures:

**A. long session (shell + Firefox), 36 min of uptime**

| | |
| --- | --- |
| faults | **543**, in **6** different VMs (`ttbr0`), **38** distinct IOVAs |
| recoveries | 6 — tasks: `noctalia` ×1, Firefox `Renderer` ×2, `firefox:gdrv0` ×3 |
| rate | bursts, e.g. 110 faults in the minute around t=1920 s |
| cadence | one IOVA (`0x1090e0000`) re-faulted exactly every ~8.0 s for minutes |
| trace window | 134 s (t=2039–2173) |

In that window the faulting VM (`ttbr0=0x1a9a0a000` → `mmu=0xffff000091322880`)
mapped/unmapped **649 distinct VAs** (1309 `ptmap`, 1074 `ptunmap`), of which
**5 are also faulting VAs**:

| IOVA | faults | map | unmap |
| --- | --- | --- | --- |
| 0x10aa30000 | 34 | 3 | 3 |
| 0x1090e0000 | 31 | 1 | 2 |
| 0x108b60000 | 8 | 3 | 3 |
| 0x108de0000 | 4 | 3 | 2 |
| 0x109c90000 | 2 | 2 | 1 |

The other **33 faulting IOVAs had no map/unmap event at all** in those 134 s.
All VM operations in the window carried **`qid=0`** and were executed by
*userspace* threads (`Renderer-4316`, `firefox:gdrv0-11271`, `niri-1720`,
`.noctalia-wrapp-…`), never by a scheduler worker.

**B. early boot, 23 s window (t=39–62), 1 fault**

| | |
| --- | --- |
| fault | t=56.876 s, `ttbr0=0x14ebad000`, `iova=0x105870000`, `source=CCU`, task `noctalia` |
| that VM | `mmu=0xffff000083500680`, 120 `ptmap` / 6 `ptunmap` **before** the fault, 116 distinct VAs |
| its page table | `ptdestroy = 0` before the fault (the four `ptdestroy`s in the window were other VMs at t=3.5–9.3 s) |
| the faulting VA | no map/unmap event in the window |
| neighbourhood | 2 s *after* the fault the same client maps `0x105860000…0x105864000` and a 5 MB range at `0x105dcb000` |

## 5. Which code paths can remove a GPU VA mapping

Everything funnels through `msm_gem_vma_unmap()` (`msm_gem_vma.c`), called from
`put_iova_spaces(obj, vm, close, reason)` (`msm_gem.c`) with these reasons:

| reason | call site | who | guard before it |
| --- | --- | --- | --- |
| `close` | `msm_gem_close()` (GEM handle close, `obj->funcs->close`) | kernel, legacy path only (returns early if `msm_context_is_vmbind(ctx)`) | `dma_resv_wait_timeout(obj->resv, DMA_RESV_USAGE_BOOKKEEP, …, MAX_SCHEDULE_TIMEOUT)` — waits for **all** fences on the BO |
| `vma_put` | `msm_gem_vma_put()` | kernel (kms VM, last handle ref) | none beyond refcounting |
| `close` | `msm_gem_unpin_iova()` | kernel, internal BOs (sqe/aqe/shadow/pm4/pfp, display) | — |
| `purge` / `evict` | `msm_gem_purge()` / `msm_gem_evict()` ← GEM shrinker | kernel, memory pressure | `is_purgeable()`/`is_unevictable()`, `msm_gem_active()`, `wait_for_idle()` |
| `free` | `msm_gem_free_object()` | kernel, last reference to the BO | BO refcounting (submits hold references) |
| `unmap` | VM_BIND `MSM_VM_BIND_OP_UNMAP` job | userspace (only if it opted into VM_BIND) | UMD must order it after the GPU work that used the VA |

Guards that matter:

* a submit pins the BOs it references (`submit_pin_objects()` /
  `vm_bind_job_pin_objects()` → `pin_count` → pinned LRU,
  `msm_gem_unpin_active()` from the fence callback);
* `msm_gem_active()` = `pin_count != 0 || !dma_resv_test_signaled(BO resv)`;
* `msm_gem_vm_close()` tears VMAs down at VM close for VM_BIND VMs (after
  waiting `vm->last_fence`), and does nothing for kernel-managed VMs —
  *"for kernel managed VMs the VMAs are torn down when the handle is closed"*.

Therefore, in the kernel-managed (legacy) model, the PTE for a BO's VA exists
from the first submit that uses it until the handle is closed (or the BO is
reclaimed/freed) — and every removal path either waits for the BO's fences or is
gated by pinning.

## 6. Ruled out, and how

| Hypothesis | Verdict | Evidence |
| --- | --- | --- |
| Mesa removes VA mappings too early (userspace-managed VM) | **ruled out** | freedreno (GL: Firefox, niri, noctalia here) never sets `MSM_PARAM_EN_VM_BIND` — `msm_pipe_set_param()` only sets `MSM_PARAM_SYSPROF`; only Turnip does (`tu_try_enable_vm_bind()`).  All captured VM ops have `qid=0` and run in userspace threads, i.e. they are `msm_gem_close()`/`msm_gem_vma_put()` teardown, not VM_BIND jobs. |
| GEM shrinker reclaimed a BO (`purge`/`evict`) | **ruled out** | not a single `purge`/`evict` op in any capture; only `close`/`vma_put`/`map` appeared. |
| The page table was destroyed under the GPU | **ruled out** for the captured faults | the faulting VM's `mmu` had `ptdestroy=0` before its fault; the early-boot `ptdestroy`s were other VMs (t=3.5–9.3 s). |
| Addresses computed wrongly because of the 7.2 UBWC rework | **weakened, not fully closed** | `FD_MESA_DEBUG=noubwc` changes nothing.  Caveat: that flag only disables UBWC for buffers *the flag's process* creates; a surface produced by another process (compositor ↔ client sharing) could still be UBWC-compressed, so re-test with the flag on *all* clients if this is revisited. |
| Fence semantics changed in 7.x | **ruled out** | `msm_fence_init()`, `msm_update_fence()` from `memptrs->fence` and `msm_job_run()` are identical to the 6.17 fork. |
| The VA teardown plumbing changed | **ruled out** | `msm_gem_close()`, `put_iova_spaces()`, `msm_gem_vma_unmap()`, the page-table `prealloc` path and the submit pin/unpin logic are identical to the 6.17 fork. |
| A newer upstream `drm/msm` fix already covers it | **no** | msm commits in mainline after 7.2.6 do not touch this path (`01c8d1f385f7` RCU-frees ring/VM objects only to keep a fence *name* alive; `140b13475302` is ARM32-only; `drm_gpuvm.c` only lost two unused helpers). |

## 7. What is left

The SMMU reports a translation fault. This alone does not establish whether
the PTE was removed, never installed, or disagrees with the hardware view.
The following three hypotheses require different fixes and must be
distinguished using mapping history and the driver's page-table view:

* **H1 — the mapping was removed while the GPU still referenced it.**
  `msm_gem_close()` waits for `dma_resv` fences. If hardware accesses persist
  after completion, their ordering must be investigated; the normal A6xx
  completion packet includes `CACHE_FLUSH_TS`. A related, but distinct,
  lifetime bug was fixed in the *hung submit* path in 7.2
  (`dc64cf9d7142` "Recover HW before retire hung submit": retiring the submit
  frees BOs the GPU is still reading).  Fix direction: quiesce (or defer the
  teardown) before removing the PTE.
* **H2 — the address was never mapped in that VM.**  Then the reference is
  stale client/hardware state (a descriptor or cached command stream pointing
  at a VA that was never mapped, or mapped in a different VM).  Fix direction:
  UMD; kernel can only detect it (and must **not** be fooled into a recovery
  loop).
* **H3 — the driver's page table says the VA *is* mapped, but the SMMU walk
  faults.**  Investigate page-table lifetime, corruption, visibility and TLB
  maintenance. The MSM custom `prealloc` mechanism is only installed for
  unmanaged VM_BIND VMs, so it does not explain a managed GL VM fault.

## 8. Instrumentation to add (the actual next step)

### 8.1 One dump in the fault handler (recommended, small)

Extend `a6xx_fault_handler()` / `adreno_fault_handler()` so that the **first**
fault of a VM prints, before the recovery runs:

1. the VM's VM-operation ring (`vm->log`, the loop already exists in
   `msm_gem_vm_unusable()`): every `map`/`unmap`/`close`/`evict` with IOVA, range
   and submitqueue id, oldest first;
2. for the faulting IOVA: the `drm_gpuva` covering it, if any
   (`drm_gpuva_find_first(vm, iova, 1)`) plus its `drm_gpuva_flags`, size and the
   owner BO (`gem.obj`: its `pin_count`, `madv`, `name`) **and** the driver's own
   `msm_gem_vma.mapped` flag;
3. the page-table translation as the driver's io-pgtable sees it. The 7.2.6
   source already has `msm_iommu_pagetable_walk(mmu, iova, ptes)` for collecting
   the four walk entries; a new `iova_to_phys` helper is not essential.

That single dump resolves §7 by inspection:

| driver VMA | page table | meaning |
| --- | --- | --- |
| exists, `mapped = false` | no translation | mapping was removed → the log's last matching entry says *who and when* (H1: compare the removal time with the fault time and with the BO's fence) |
| exists, `mapped = true` | translation present | the SMMU/hardware disagrees with the page table → H3 |
| no VMA | no translation | absent now: either already removed or never mapped; distinguish using interval history |

Constraints: an interrupt-context dump cannot simply walk the GPUVA tree or
page tables without lifetime and concurrency protection. In the managed GL
path, `vm_log()` does **not** require `vm->mmu_lock`; the source only asserts
that lock for unmanaged VMs. A non-blocking lookup alone is not safe. Any new
dump must establish VM identity/lifetime and the appropriate locking, or use
the existing deferred crash-state capture path with its locking constraints.

### 8.2 Cheap alternatives that need no patch

* `msm.vm_log_shift=8` + `msm.vm_log_dmesg=1`
  (`pkgs/kernel/mainline-latest/debug/vm-log-dmesg.sh`, built with
  `nabu-msm-module`) prints every VM map/unmap with its reason and queue id from
  the driver itself, no kprobes needed.
* kprobes already used (see `scripts/nabu-ccu-fault-capture.sh`):

```
p:vmop     vm_log                            vm=%x0 op=+0(%x1):string iova=%x2 range=%x3 qid=%x4
p:vmunmap  msm_gem_vma_unmap                 vma=%x0 reason=+0(%x1):string va=+24(%x0):x64
r:ptparams msm_iommu_pagetable_params        mmu=$arg1 ttbr=+0($arg2):x64 asid=+0($arg3):x32
p:ptmap    msm_iommu_pagetable_map           mmu=%x0 iova=%x1 sgt=%x2 len=%x4
p:ptunmap  msm_iommu_pagetable_unmap         mmu=%x0 iova=%x1 len=%x2
p:ptdestroy msm_iommu_pagetable_destroy      mmu=%x0
p:vmfree   msm_gem_vm_free                   gpuvm=%x0
p:unusable msm_gem_vm_unusable               gpuvm=%x0
```

  `va=+24(%x0)` is `drm_gpuva.va.addr` computed from `include/drm/drm_gpuvm.h`
  (`vm` 8 + `vm_bo` 8 + `flags` 4 + padding 4); it should be cross-checked
  against the `iova=` of the matching `ptunmap` line at runtime.
* For H3 specifically: boot with `slub_debug=FZPU` (or KASAN in a test build) so
  a use-after-free/reuse of page-table pages is reported, and keep
  `CONFIG_DEBUG_PAGEALLOC` in mind for the page-table cache
  (`get_pt_cache()` in `msm_iommu.c`).

## 9. If instrumentation is not enough: bisect

Known-good: `v6.17.0-sm8150` (no faults) and known-bad: 7.2.6.  The change is
somewhere between, so a bisect across the 7.x merges of `drivers/gpu/drm/msm`
is the fallback.  Feature-level suspects to test *before* a full bisect, because
each can be enabled/disabled or reverted alone:

* the UBWC configuration rework merged for 7.2 (`drm-msm-next-2026-08-01`:
  "Trust the SSoT UBWC config", "correct UBWC programming sequences",
  "set fp16compoptdis for UBWC 3.0 formats", the `qcom_ubwc_version_tag()` /
  macrotile / amsbc / min_acc_length helpers);
* the GPU recovery and scheduler changes in 7.2 (`drm/msm: Recover HW before
  retire hung submit`, `Only fini scheduler after successful init`,
  `Fix task_struct reference leak in recover_worker`, the a6xx IRQ-storm fix,
  `a6xx: Fix stale rpmh votes after suspend`);
* GMU-side changes (`Increase GMU FW init timeout`, perfcntr/timestamp rework).

## 10. Artifacts and how to collect them

On the device (all of this is already in the repo):

```sh
sudo bash scripts/nabu-ccu-fault-capture.sh          # manual, waits for a fault
# or boot with nixos/debug/ccu-capture.nix imported, so it is armed before the
# Wayland session starts (the first fault of a boot happens while the shell
# comes up), plus boot.kernelParams = [ "msm.vm_log_shift=8" ]
sudo bash scripts/nabu-ccu-fault-capture.sh --analyze-only /var/lib/nabu-ccu
```

Each capture leaves `SUMMARY.txt` (fault statistics, per-IOVA events,
`mmu → ttbr` table, `ptdestroy`/`vmfree` timeline, driver `vm-log` dump if
enabled), `dmesg-full.txt`, `trace-full.txt` and
`trace-before-first-fault.txt`.  Those four files are what a kernel developer
needs; `SUMMARY.txt` is self-explanatory.

## 11. Suggested upstream report

Subject along the lines of `drm/msm: SM8150 (a640) reads unmapped VAs — CCU
translation faults and GPU resets on 7.2`, to `dri-devel@lists.freedesktop.org`
and `freedreno@lists.freedesktop.org`, containing: the fault lines, the fact
that the userspace here is freedreno GL (so kernel-managed VM, no VM_BIND), the
exclusion list of §6, the observation that the same userspace on 6.17 is clean
while the mapping/fence plumbing is byte-identical, and the request for the
dump from §8.1 (or guidance on which of H1–H3 is anticipated).  Worth linking:
the recovery ordering fix `dc64cf9d7142`, the evict-list fix `8a61c211d0d5`, and
the VM/ring RCU fix `01c8d1f385f7` as the class of bug this looks like.

## 12. Source audit and candidate patch: missing A640 CX GBIF setup

### 12.1 What is established in the source

The audited 7.2.6 tarball is byte-identical to the source used by the locked
Nix derivation (SHA-256
`039aef84f2b0994aeda3f4fcfc3d02ec9d7a9bbb9020ea264c43f446c860f606`).
Comparison with **upstream v6.17** reveals an initialization regression outside
GEM teardown. This comparison is not a claim that every file in the downstream
`v6.17.0-sm8150` tree is identical to upstream.

* In upstream v6.17, `adreno/a6xx_gpu.c:hw_init()` writes
  `GBIF_QSB_SIDE0..3 = 0x00071620` for `adreno_is_a640_family()` as well as
  the other supported GBIF families.
* In 7.2.6, that block only handles `adreno_is_a610_family()`. GMU devices
  instead rely on `adreno/a6xx_gmu.c:a6xx_gmu_fw_start()` iterating
  `adreno_gpu->info->a6xx->gbif_cx` before starting the GMU.
* `adreno_is_a640_family()` means `ADRENO_6XX_GEN2`: A640 (`0x06040001`,
  the nabu) and A680 (`0x06080001`). Both catalog entries have
  `.hwcg = a640_hwcg` and `.protect = &a630_protect` but **no `.gbif_cx`**.
  A NULL list makes the new loop skip all four writes.
* The correct four values already exist in `a6xx_catalog.c:a640_gbif`.
  Adding `.gbif_cx = a640_gbif` to the two entries restores their old
  settings through the current initialization path. It does not change
  allocation, PTEs, fence completion, cache flush packets or recovery.

This omission is a concrete source defect, rather than a proposed arbitrary
GPU delay. It is still a **candidate explanation for the captured faults**:
we have neither a register readback from the faulting device nor a patched
boot proving that this defect caused those accesses. The evidence does not
justify claiming that GBIF generates a particular malformed address.

The upstream discussion is useful context: the
[original review](https://lists.openwall.net/linux-kernel/2025/11/12/663)
identified missing A640/A650 family entries; the
[author acknowledged it](https://lists.openwall.net/linux-kernel/2025/11/12/1899).
The [v4 cover letter](https://lists.infradead.org/pipermail/linux-arm-kernel/2025-November/1081359.html)
says that issue was addressed, but the actual 7.2.6 catalog still omits the
GEN2 entries. The shipped source, not that cover-letter claim, is the basis
of this patch.

The patch is
[`patches/0009-drm-msm-a6xx-restore-a640-gbif.patch`](../pkgs/kernel/mainline-latest/patches/0009-drm-msm-a6xx-restore-a640-gbif.patch),
i.e. part of the kernel package's series, so a build of
`nabu-kernel-mainline-latest` contains it and the kernel build from before that
patch is the control it has to be compared against.  It is applied by
`pkgs/kernel/mainline-latest/default.nix`, and the fast path in
`msm-module.nix` picks it up with the rest of `patches/`.

### 12.2 Corrections to the original inference

The original analyzer in `scripts/nabu-ccu-fault-capture.sh` searches for exact
`iova=` matches. A fault at `v` must instead be compared to **every interval**
`start <= v < start + range` in the **same VM**, in timestamp order. A missing
exact-start event does not mean the VA was never mapped. The old `ptmap`
probe in capture A also recorded `x2` (the SG pointer) as `len`; use the
`vmop range` values for that capture. The current probe uses `x4` correctly.
Mapping entry probes describe attempts, not successful return values.

Re-reading the actual long capture (`/tmp/ccu-real2`, VM
`0xffff0000ae190800`, MMU `0xffff000091322880`, TTBR `0x1a9a0a000`) illustrates
why this matters:

| Fault time / address | Earlier interval events in that VM |
| --- | --- |
| 2085.469026 / `0x109c90000` | map of `0x109c9d000`, range `0x280000`, at 2085.468; fault is **below** this new BO, not inside it |
| 2095.194387 / `0x10d6c0000` | close of `0x10d44d000`, range `0x280000`, at 2095.058 **covers** the fault; another BO begins at `0x10d6cd000` |
| 2166.383898 / `0x102300000` | close of `0x10208d000`, range `0x280000`, at 2164.152 **covers** the fault; another BO begins at `0x10230d000` |

All 38 distinct fault addresses in that capture are 64 KiB aligned. Some are
the 64 KiB round-down of another BO's start. This is worth investigating, but
is not proof that BO alignment is the bug or that the GPU accessed the BO
which was closed. Increasing every BO's alignment could hide an invalid
access by changing VA layout; it is not the fix supplied here.

Two other source-level qualifications:

* The custom `prealloc` allocator is installed only under
  `if (!kernel_managed)` in `msm_iommu_pagetable_create()`. Its cleanup is not
  the allocator for the legacy GL VM described in this report.
* Equal fence-accounting code does not prove equal hardware completion.
  Conversely, upstream v6.17 and 7.2.6 both end `a6xx_submit()` with the
  `CACHE_FLUSH_TS` packet; it is inaccurate to infer that these fences only
  mean the CP has parsed commands. Additional cache ordering would require
  evidence of the specific outstanding transaction.

### 12.3 How the candidate is built and booted

The patch is part of the kernel package's series, so the build that has to run
is the kernel build - `.github/workflows/build-kernel.yml` or the linux-builder
produces `nabu-kernel-mainline-latest` and the Cachix cache carries it to the
device:

```sh
nix build .#packages.aarch64-linux.nabu-kernel-mainline-latest --out-link result-kernel
```

A one-off variant can also be added without touching the package:

```nix
nabu.kernel.name = "mainline-latest";
boot.kernelPatches = [ {
  name = "a640-gbif-initialization";
  patch = ../pkgs/kernel/mainline-latest/patches/0009-drm-msm-a6xx-restore-a640-gbif.patch;
} ];
```

That relative path assumes the snippet is in `nixos/configuration.nix`.

On the device, boot the new kernel and keep the previous generation in the
systemd-boot menu - that build (without `0009`) is the control.  The capture
service is orthogonal:

```nix
nabu.kernel.name = "mainline-latest";
imports = [ ./debug/ccu-capture.nix ];
```

#### The swap is not the kernel's own build (measured)

`nabu-msm-module` compiles `drivers/gpu/drm/msm` through `make M=... modules`
against `${kernel.dev}`. That is a *different compilation* from the one the
shipped `msm.ko` went through.  Comparing the two artefacts of the same locked
kernel (same tarball, same patches, same `.config`, same GCC 15.3.0):

| | shipped `msm.ko` | rebuilt by `msm-module.nix` |
| --- | --- | --- |
| size | 2480712 B | 2549808 B |
| `.text` | 705484 B | 779840 B |
| `.rodata` | 408573 B | 397027 B |
| functions with a different size | - | 2042 of 2044 |
| `modinfo` | `intree=Y` | absent |
| `__offset_CTL.part.0` | `brk #0x800` | `paciasp; stp x29, x30, [sp, #-0x10]!; mov x29, sp; brk #0x800` |

`msm` is the display driver and is loaded from the initrd before the root
filesystem exists, so a swapped module is a different driver, not the shipped
driver plus one register-list change. A single boot from it cannot decide
whether the GBIF candidate fixes, breaks or does nothing to the CCU faults - a
black panel with an otherwise healthy system is exactly as likely to come from
the rebuild as from the patch.

That was measured as well: booting the *unpatched* rebuild leaves the panel
dark exactly like the candidate, so the rebuild - not the GBIF patch - is what
breaks the display path, and the patch itself is still unverified.  The
shortcut is therefore left to build-time iteration and to observing the driver:
`nixos/debug/a640-gbif-fix.nix` installs the module built with
`debug/vm-log-dmesg.sh` (the `msm.vm_log_dmesg` parameter), which is read over
ssh while the screen stays dark; add
`boot.kernelParams = [ "msm.vm_log_shift=8" ]` for the driver's own ring as well,
and note that kprobes need no swapped module at all.  Do not attempt to unload
the active display's `msm`, and do not copy a `.ko` into an existing initrd.

### 12.4 Validation and acceptance criteria

Completed locally / on the configured ARM64 Linux builder:

* Applied the original eight patches and this candidate to the locked 7.2.6
  source with `patch -p1 -F0 --forward`: all applied, no fuzz.
* `checkpatch.pl --no-tree --strict --no-signoff`: zero errors or warnings.
  This local candidate has no invented author sign-off or hardware Tested-by.
* Built the candidate through the module path (`nabu-msm-module` plus the
  patch): compilation, MODPOST and link succeeded, vermagic
  `7.2.6 SMP preempt mod_unload aarch64`.  That is no longer the route the
  device is tested with (12.3), but it established that the patch compiles and
  links, before the module shortcut was found to be unsound.
* Booted both the *unpatched* rebuild and the candidate on the device: both
  leave the panel dark, so the shortcut itself is what has to be avoided.

**Not performed:** a kernel build containing `patches/0009-...`, boot
verification of that kernel, GPU workload testing, or suspend/resume. Keep a
known-good boot generation.
Compare an unpatched 7.2.6 boot and a patched boot using the same userspace,
firmware, environment and workload, preferably multiple cold boots. Exercise
shell startup, Firefox, and suspend/resume for at least the original 36-minute
capture duration. Count first faults and recoveries, not just rate-limited
fault messages. Revert the import to reproduce the baseline if the candidate
looks clean.

If a fault still occurs, preserve the first `/sys/class/devcoredump/devcd*/data`
before it expires, plus the four capture files in §10. The existing A6xx
coredump register list includes `0x3c00..0x3c0b`; `GBIF_QSB_SIDE0..3` are GPU
register offsets `0x3c03..0x3c06` and should contain `0x00071620` after this
patch. Such a dump checks whether the initialization change took effect;
it does not by itself validate the fault hypothesis. If the registers are
correct but faults persist, continue with interval-aware first-fault and
command-stream analysis rather than declaring this patch a fix for the storm.
