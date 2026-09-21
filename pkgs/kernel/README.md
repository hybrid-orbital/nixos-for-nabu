# Kernels

One directory per kernel.  Each directory is a self-contained package and is
listed once in [`default.nix`](default.nix):

```text
pkgs/kernel/<name>/default.nix   the kernel derivation
pkgs/kernel/<name>/patches/      downstream patches, applied in order
pkgs/kernel/<name>/configs/      kconfig fragment + required settings
```

The directory name is also the kernel's name in
[`default.nix`](default.nix), in the flake package outputs
(`.#nabu-kernel-<name>`) and in the `nabu.kernel.name` NixOS option.

Building one kernel needs no system closure — this is the cheap way to check a
patch rebase or a configuration change:

```sh
nix build .#nabu-kernel-mainline-latest
nix build .#nabu-kernel-sm8150-fork
```

`nabu.kernel.name` is an ordinary NixOS option (an enum of the names registered
in `default.nix`), so choosing the kernel for the *system* means setting it in
configuration like any other option:

```nix
# nixos/configuration.nix, or a module of your own
{
  nabu.kernel.name = "mainline-latest";
}
```

```sh
sudo nixos-rebuild switch --flake .#ext4-nabu
```

Two things to keep in mind:

- `nixos-rebuild --option` is **not** how this option is set.  That flag passes
  Nix settings (such as `substituters`) through to Nix itself.
- A git flake only sees tracked files, so a new module file has to be
  `git add`ed before `nixos-rebuild` can see it.

To try a kernel without editing the repository at all, override the option
while building the system and activate that store path (the previous
generations, with the other kernel, stay bootable):

```sh
nix build --impure --expr '
  let f = builtins.getFlake (toString ./.);
  in (f.nixosConfigurations.ext4-nabu.extendModules {
       modules = [ { nabu.kernel.name = "mainline-latest"; } ];
     }).config.system.build.toplevel'
sudo nixos-rebuild switch --store-path "$(readlink -f result)"
```

## Available kernels

| Name | Source | Notes |
| --- | --- | --- |
| `sm8150-fork` | sm8150-mainline/linux `v6.17.0-sm8150` | Default.  The pinned downstream tree, built from its own `sm8150.config` defconfig; `patches/` only carries the nabu runtime fixes. |
| `mainline-latest` | nixpkgs `linux_latest` | nixpkgs' stock kernel plus `patches/`, a rebase of the downstream nabu support (device tree, panel, touchscreen, sound card, charging, runtime fixes) that is not upstream yet. |

`sm8150-fork` is the known-good kernel for the device.  `mainline-latest`
tracks upstream and is the kernel under test: it is expected to gain the
remaining downstream drivers as they are rebased, and to eventually replace
the fork once it is verified on hardware.

### Status of `mainline-latest`

Verified:

- every patch in `patches/` applies to a pristine nixpkgs `linux-7.2.3` tree
  with no fuzz and no rejects;
- kconfig resolves with our fragment (`configs/nabu.config`); on arm64 an
  option kconfig cannot satisfy is a build error, so this also checks the
  fragment itself;
- `nix build .#nabu-kernel-mainline-latest` completes: `Image`,
  `dtbs/qcom/sm8150-xiaomi-nabu.dtb` and the nabu modules are all built
  (`nt36523_ts`, `panel-novatek-nt36523`, `ktz8866`, `msm`, `ufs-qcom`,
  `qcom_fg`, `idtp9418`, `qcom_smbx`, `ath10k_snoc`, `snd-soc-sm8150`,
  `snd-soc-cs35l41-i2c`, ...), and the `postConfigure` check passes against
  the resolved `.config`;
- the flake evaluates (`nix flake check --no-build --all-systems`) and
  `sm8150-fork` keeps its existing store path, so the published cache still
  applies to the default kernel.

The first on-device boot of this kernel stopped right after the EFI stub
handed over: grey screen, no output, no response.  Two port defects caused it,
both fixed since:

- **The device tree lost the `refgen` regulator.**  Upstream 7.2.3 already has
  `refgen: regulator@88e7000` plus the `refgen-supply` links on both DSI
  controllers, while the downstream tree carries its own copy of that node
  (from a time when upstream did not have it).  Rebuilding the port from the
  downstream tree ended up *deleting* upstream's node, and the msm DSI host
  then silently falls back to a dummy regulator (`dsi_host.c` does a mandatory
  `devm_regulator_bulk_get_const()` of `{ vdda, refgen }`), so REFGEN is never
  enabled and the panel shows nothing.  Since arm64 has no EFI framebuffer
  handover, that removes the only console the device has — which is why the
  boot looked like a hang.
- **The initramfs was missing boot-critical modules.**  The 6.17 fork kernel
  builds the UFS controller, its QMP PHY, DRM/MSM and the REFGEN regulator in;
  `mainline-latest` gets them as modules from nixpkgs' common config.  The
  QMP UFS PHY is matched through the device tree, not through a symbol
  dependency, so it was not pulled into the initramfs automatically and
  `ufs_qcom_init()` returned `-EPROBE_DEFER` forever: the root filesystem
  never appeared.  `nixos/hardware-nabu.nix` now lists `phy_qcom_qmp_ufs`,
  `qcom_refgen_regulator`, `phy_qcom_qmp_combo` and `typec`, and
  `configs/nabu.config` builds the pstore backends in so a boot that still
  fails leaves its log in the ramoops region.

Verified after the fix: the patch series still applies to a pristine tree with
no rejects, the kernel builds, the *built* DTB contains the `refgen` node and
both `refgen-supply` links, and the *built* initramfs contains
`phy-qcom-qmp-ufs`, `qcom-refgen-regulator`, `ufs-qcom`, `ufshcd-core/pltfrm`,
`msm`, `panel-novatek-nt36523`, `ktz8866`, `phy-qcom-qmp-combo` and `typec`
(37 modules in total).

One further fix comes from the same on-device comparison:

- `patches/0001-...` wires `vbus-supply = <&pm8150b_vbus>` into the Type-C
  connector.  Upstream moved that supply from the port's `vdd-vbus-supply` to
  the connector's `vbus-supply`; with neither present the PMIC Type-C driver
  gets a dummy regulator (`qcom_pmic_typec_port.c`), never enables VBUS and OTG
  devices are then only detected intermittently.  The supply provider
  (`REGULATOR_QCOM_USB_VBUS`) is a module, so in the initramfs the Type-C port
  probe just defers until the root filesystem is mounted; nothing in the boot
  path depends on it.

### Tried and reverted: the downstream clock workaround

The nabu kernels also carry a pair of clock changes (a 2.5 ms settle time in
`clk_enable_regmap()`/`clk_disable_regmap()` plus `BRANCH_HALT_SKIP` →
`BRANCH_HALT_DELAY` for the UFS PHY symbol clocks) described as fixing "clock
stuck in off/on state, broken UFS on boot and broken DSI on suspend/resume".
Porting them made `mainline-latest` **unbootable on the device** (grey screen,
then the display went dark), so the patch was dropped again:

- the settle time runs inside `clk_enable_regmap()`, which the clock core calls
  while holding `enable_lock` with interrupts disabled (`drivers/clk/clk.c`),
  i.e. every toggle of every regmap clock (gcc, dispcc, gpucc, camcc, …) adds
  2.5 ms of IRQ-off time during boot.  That is the most likely reason the boot
  died;
- the `BRANCH_HALT_DELAY` half is nearly a no-op in current kernels
  (`clk_branch_wait()` just does `udelay(10)` and returns 0, it does *not* poll
  the halt bit), so it is harmless on its own but also does not do what the
  downstream commit describes.

If this is picked up again, do it one half at a time, outside the IRQ-disabled
path (for example as a delay in the UFS/DSI *drivers* rather than in the generic
regmap clock helper), and verify with the diagnostics workflow below.

### GPU faults under load: 7.2.6 or newer

With 7.2.3, Firefox (WebRender) flooded dmesg with

```
*** gpu fault: ttbr0=... iova=0000000101600000 dir=READ type=TRANSLATION source=CCU
```

and the ring hangcheck then recovered the GPU (`hangcheck recover!`,
`offending task: firefox:gdrv0`), which the client reports as a device reset and
shows as a short black screen.  The GPU was reading memory whose mapping had
already been torn down.

That is a known bug in 7.2.3, fixed in the 7.2.y stable releases right after it
(accepted between the 7.2.3 and 7.2.6 tags, so **7.2.6 is the minimum this
package should be built from**):

* `drm/msm: Recover HW before retire hung submit` — retiring the hung submit
  before recovering the GPU freed its BOs while the GPU was still reading them,
  which is exactly the page-fault pattern above;
* `drm/msm: remove objects from evit list after pinning them` (VM_BIND);
* `drm/msm: dpu|dsi|dp: Drop sneaky dev_pm_opp_set_rate(0)` — the display
  pipeline could run without the power backing its required-opps ask for, which
  is also a candidate for the higher idle draw;
* `drm/msm/dsi: round 6G byte clock rate to the PLL-achievable value` and the
  bonded-mode PLL revert — panel glitches on runtime DCS commands;
* `drm/msm/a6xx: Fix stale rpmh votes after suspend` and the a6xx recovery
  IRQ-storm fixes.

The kernel version follows `flake.lock`; the nixpkgs input was updated to the
revision that ships 7.2.6 (`20b1ddd1`, 2026-09-19).  `linux_latest.override`
cannot be used to select a kernel version — it silently keeps whatever version
the pinned nixpkgs has — so version bumps go through the flake input, followed
by a patch application test (the seven patches still apply to 7.2.6 with no
rejects).

An earlier attempt blamed the UBWC parameter rework and forced the pre-rework
swizzle/highest-bank-bit values for `adreno_is_a640()`.  That made no
difference to the faults and was reverted; the UBWC code is identical in 7.2.3
and 7.2.6.

To check a future kernel: run the same Firefox workload and
`sudo dmesg | grep -iE 'gpu fault|hangcheck recover'` — both should stay quiet.

#### Still reproducing on 7.2.6 (2026-09-21)

The storm above is **not** fixed on 7.2.6 plus the DSI fix: Firefox still
produces, after roughly seven minutes of use,

```
*** gpu fault: ttbr0=000000014533e000 iova=0000000101600000 dir=READ type=TRANSLATION source=CCU (0,0,0,1)
adreno 2c00000.gpu: [drm:a6xx_irq] *ERROR* gpu fault ring 0 fence d1a9 status 00800005 rb 04a0/0505 ib1 .../...
msm_dpu ae01000.display-controller: [drm:recover_worker] *ERROR* 06040001: hangcheck recover!
msm_dpu ae01000.display-controller: [drm:recover_worker] *ERROR* 06040001: offending task: firefox:gdrv0
```

(storm from ~443 s, first recovery at ~587 s, repeating every few minutes).
Reading the driver: `type=TRANSLATION` is the SMMU FSR.TF, i.e. *no valid PTE*
for that IOVA at that instant, and `source` is `a6xx_fault_block(fsynr1 & 0xff)`
with id 4 = `CCU` (`adreno/a6xx_gpu.c`).  The line comes from
`adreno_fault_handler()` (`adreno/adreno_gpu.c`), which deliberately turns
stall-on-fault off for 500 ms after the first fault — the long storms with
`callbacks suppressed` are the designed behaviour, not a printk problem.  The
recovery is `a6xx_fault_detect_irq()` (RBBM fault detect, `status 00800005`)
queueing `recover_work`, which resets the GPU; that is the "driver reload" seen
on the device.

Nothing newer upstream addresses it: the msm commits in mainline *after* 7.2.6
do not touch this path (`01c8d1f385f7` RCU-frees the ring/VM objects, but only
to keep a *fence name* alive for `SYNC_IOC_FILE_INFO`; `140b13475302` is
ARM32-only; `drivers/gpu/drm/drm_gpuvm.c` only lost two unused helpers).  So the
fault has to be localised on the device.  A mapping can only disappear through
three paths here, and all of them funnel through `msm_gem_vma_unmap()` with a
reason string:

* an explicit userspace `MSM_VM_BIND_OP_UNMAP` (`vm_unmap_op()`);
* the GEM shrinker evicting or purging the BO (`put_iova_spaces(..., false,
  "evict"/"purge")` in `msm_gem.c`);
* BO/VM teardown (`close = true`, reasons `free`/`close`).

Submits keep their BOs pinned for the lifetime of the submit
(`submit_pin_objects()` / `vm_bind_job_pin_objects()` → `pin_count` → pinned LRU,
released by `msm_gem_unpin_active()` from the fence callback); that pin is the
only protection against the shrinker case.  The fork kernel (6.17) has no
VM_BIND at all and keeps a VA for the BO's lifetime, which is why the same Mesa
does not fault there.

On the device, `scripts/nabu-ccu-fault-capture.sh` does the first pass for you:

```sh
sudo bash scripts/nabu-ccu-fault-capture.sh     # then just use Firefox
```

It arms kprobes on `vm_log()`, `msm_iommu_pagetable_{params,map,unmap,destroy}`,
`msm_gem_vm_free()` and `msm_gem_vm_unusable()`, waits for the first
`*** gpu fault: ttbr0=…` line, snapshots the trace buffer at that moment, keeps
tracing until the recovery (or `--grace`), and then prints a summary that
answers, for that specific fault: did the faulting IOVA see any per-VA event
(and which reason), was its page table - identified by matching the fault's
`ttbr0` against `msm_iommu_pagetable_params()` - destroyed before the fault, and
did the driver print its own `vm-log:` dump (needs `msm.vm_log_shift=8`).

##### Conclusion: an msm lifetime bug, not userspace, reclaim or UBWC

What the evidence rules out, and what ruled it out:

| Hypothesis | Verdict | Evidence |
| --- | --- | --- |
| Mesa/UMD removes VA mappings too early (VM_BIND) | ruled out | freedreno (the GL driver Firefox, niri and noctalia use here) never sets `MSM_PARAM_EN_VM_BIND` — only Turnip does.  Every VM op captured carries `qid=0` and comes from a userspace thread, i.e. the kernel-managed path, where `op="close"` is `msm_gem_close()` and `op="vma_put"` is `msm_gem_vma_put()`. |
| The GEM shrinker reclaimed a BO (`purge`/`evict`) | ruled out | no `purge`/`evict` op ever appeared in any capture; the only teardown ops were `close` and `vma_put`. |
| The whole page table was freed under the GPU | ruled out for the faults captured | the faulting VM's mmu had `ptdestroy=0` before its fault; the four `ptdestroy`s in the early-boot capture were other VMs at t=3.5–9.3 s. |
| Wrong addresses from the 7.2 UBWC rework | ruled out | `FD_MESA_DEBUG=noubwc` (freedreno has that flag: "disable UBWC for all internal buffers") makes no difference. |
| Changed fence semantics in 7.x (fence signalled earlier) | ruled out | `msm_fence_init()`, `msm_update_fence()` from `memptrs->fence` and `msm_job_run()` are identical to the 6.17 fork, which does not fault. |
| The VA teardown plumbing itself changed | ruled out | `msm_gem_close()`, `put_iova_spaces()`, `msm_gem_vma_unmap()` and the page-table prealloc path are identical to the 6.17 fork. |

What remains: the GPU (CCU) reads VAs whose PTE is gone, in a driver whose
map/unmap plumbing is the same as the one that does *not* fault on 6.17, with
the mappings removed only by the kernel's own BO teardown — and that teardown
waits for the BO's `dma_resv` fences first (`msm_gem_close()`).  In other words
*fence signalled ≠ hardware quiesced*, and none of our captures show the
removal that the GPU outlived.  Getting further needs either a kernel version
bisect (6.19 → 7.2, several full kernel builds) or upstream input; the
device-side probing has reached the end of what it can tell us.

Consequence for this repo: `mainline-latest` boots and drives the panel, but
under GL load it reliably produces these fault storms and a GPU recovery
(screen glitching, sometimes black, then a redraw).  **`sm8150-fork` stays the
default and the kernel for daily use**; `mainline-latest` is a test target
until this is understood upstream.

The full report — measurements, the audit of every path that can remove a VA
mapping, the exclusion table, the remaining hypotheses and the in-kernel dump
that should settle them — is in
[docs/kernel-gpu-fault.md](../../docs/kernel-gpu-fault.md).

The capture tooling stays for whoever picks this up: a capture has to be
running *before* the fault, and the first fault of a boot happens while the
shell comes up, in a VM created earlier.
`nixos/debug/ccu-capture.nix` runs the script as a systemd service before
`graphical.target` (which is what gets `msm_iommu_pagetable_params()` for that
VM); add `boot.kernelParams = [ "msm.vm_log_shift=8" ]` for the driver's own
vm-log ring as well.  With the shell running one IOVA was re-read every 8 s, so
a capture started by hand also sees a fault within seconds.

### Fast iteration: building only the DRM modules

A full `nix build .#nabu-kernel-mainline-latest` is tens of minutes; while
chasing a driver bug only the driver under test has to be compiled:

```sh
nix build .#nabu-msm-module          # ~30 s; result/ then holds msm.ko
```

`pkgs/kernel/mainline-latest/msm-module.nix` unpacks the kernel source, applies
the same patch series the kernel package applies, and then runs
`make -C ${kernel.dev}/lib/modules/<version>/build M=… modules` against the
already built kernel's kbuild tree (its `.config`, `Module.symvers` and
generated headers).  The kernel is built without `CONFIG_MODVERSIONS` and
`CONFIG_MODULE_SIG`, so the result carries the same vermagic
(`7.2.6 SMP preempt mod_unload aarch64`) as the shipped module and can be loaded
on the device instead of rebuilding the kernel.  Three knobs extend it:

* `dirs = [ … ]` — which directories to compile (default
  `[ "drivers/gpu/drm/msm" ]`; add `"drivers/gpu/drm/panel"` for panel work);
* `extraPatches = [ … ]` — extra patch files applied on top;
* `extraShell = "…"` — a shell snippet run inside the source tree after the
  patches, for debug-only instrumentation.

`debug/vm-log-dmesg.sh` is exactly such a snippet: it adds a
`msm.vm_log_dmesg` module parameter that prints every VM map/unmap with its
reason and submitqueue id, so the faulting IOVA can be correlated with the unmap
that removed it (a kprobe on `vm_log()` does the same without any rebuild —
`CONFIG_KPROBES`, `CONFIG_KPROBE_EVENTS` and `CONFIG_DYNAMIC_FTRACE` are all
enabled in this kernel).  Build it with:

```sh
nix build --impure --expr '
  let f = builtins.getFlake (toString ./.);
  in (f.packages.aarch64-linux.nabu-msm-module.override {
       extraShell = builtins.readFile ./pkgs/kernel/mainline-latest/debug/vm-log-dmesg.sh;
     })'
```

Two further discriminators need no rebuild at all: `msm.enable_eviction=0`
(module parameter, writable at runtime) removes the shrinker eviction path, and
`FD_MESA_DEBUG=noubwc` / `TU_DEBUG=noubwc` removes UBWC compression, i.e. the
traffic the CCU is normally busy with.

#### 7.2.6 needs the bonded-mode DSI fix re-applied

With 7.2.6 the device boots and the GPU faults are gone, but most of the screen
showed stripes with only a thin intact strip on the left.  The Pad 5 panel is a
**dual-DSI (bonded)** panel: one PLL in the primary DSI PHY clocks both links.
Upstream commit `93c97bc8d85d` ("drm/msm: dsi: fix PLL init in bonded mode",
present in 7.2.3) made that work by keeping `pll_enable_cnt` in the bias
enable/disable path only; 7.2.6 **reverts** it because the same change broke
non-bonded use ("Clock divider is being programmed incorrectly, resulting in the
wrong display mode being selected").  Without it the secondary PHY sets the PLL
without initialising the clocks, so the second link outputs a broken stream —
exactly the observed stripes.

`patches/0008-drm-msm-dsi-restore-bonded-mode-pll-fix.patch` re-applies the
upstream fix on top of the revert (it applies to 7.2.6 unchanged), so the
device keeps the bonded-mode behaviour of 7.2.3 while keeping the 7.2.6 GPU
fixes.  A later kernel that lands a proper bonding fix can drop this patch.

Why upstream reverted it in the first place (what this patch knowingly
re-introduces):

* the fix broke the **non-bonded** case.  Mohit Dsor (Qualcomm) reported on
  2026-04-26 on a Thundercomm RB3 Gen2 with an lt9611uxc DSI→HDMI bridge: "720p60
  it will be 720p30.  Even though the byte_clk is set correctly, the bridge is
  receiving half the byte clock.  Some divider is getting set which is causing
  the byte_clk to get half, ultimately fps to get half" — and reverting the
  commit locally fixed it
  (`https://lore.kernel.org/r/ae07cef84AmXK43H@hu-mdsor-hyd.qualcomm.com`,
  clk_summary and DSI PHY register dumps followed on 2026-05-05);
* Dmitry Baryshkov reverted it as `44784327815b` ("Clock divider is being
  programmed incorrectly, resulting in the wrong display mode being selected.
  Revert the offending commit, letting Neil to work on a better fix",
  https://patchwork.freedesktop.org/patch/739459/), which reached 7.2.6 as the
  stable backport `5de981b7db1f`;
* that breakage is a single-DSI link driving an HDMI bridge, which is not what
  this device does: the Pad 5 is bonded (`qcom,dual-dsi-mode` +
  `qcom,sync-dual-dsi`, with DSI1 taking DSI0's PLL as parent), i.e. exactly the
  configuration the reverted commit was fixing;
* the promised replacement fix has not landed yet: the reverted 7.2.6 code is
  still what mainline HEAD *and* the msm tree's `msm-next` branch ship (both
  files fetched and diffed against the 7.2.6 one), so there is nothing better to
  apply today.  When Neil Armstrong's follow-up lands, drop this patch.

Why this and not one of the other 7.2.3 → 7.2.6 display changes (checked against
the extracted upstream trees rather than inferred):

* `diff -r` of `drivers/gpu/drm/msm` between v7.2.3 and v7.2.6 leaves four
  display-relevant changes: this revert, the byte clock rounding below, the two
  `dev_pm_opp_set_rate(0)` removals (performance votes, not pixel data) and the
  DPU v13 / DisplayPort changes in `dpu_hw_catalog.c` and `dpu_encoder.c`, none
  of which an sm8150 DSI panel uses;
* the byte clock rounding added to `dsi_calc_clk_rate_6g()` is a no-op for this
  panel: the mode asks for 585.137 MHz pclk, 292.57 MHz per link (halved for
  bonded DSI), i.e. a C-PHY byte clock of 146.28 MHz (`pclk * bpp /
  (16 * lanes)` with 24 bpp over 3 trios) and a VCO of 1.17–2.34 GHz depending
  on the post-divider.  That is inside the 1.0–3.5 GHz window of
  `dsi_phy_7nm_8150_cfgs` and the fractional divider can hit it exactly, so
  `clk_round_rate()` returns the request unchanged - the rounding only matters
  for modes whose VCO falls outside that window;
* the 6.17 fork kernel (known good on the device) has no `pll_enable_cnt` at
  all: its `dsi_pll_enable_pll_bias()` always writes the PLL bias and mux
  registers, which is the behaviour the 7.2.3 code has and this patch restores;
* applying patch 0008 to a 7.2.6 tree makes `dsi_phy.h` and `dsi_phy_7nm.c`
  byte-identical to the v7.2.3 files (`patch -p1`, then `diff` against the
  extracted trees), and mainline HEAD still ships the reverted 7.2.6 version —
  there is no newer upstream bonded-mode fix to prefer over this one.

Not verified yet: a boot with this patch applied.  If the stripes stay, the next
thing to look at is the DSI clock tree on the device — `scripts/nabu-diagnostics.sh`
captures `clk_summary`, so the byte and pixel clock rates of `mdss_dsi0` and
`mdss_dsi1` can be compared with a boot of the fork kernel.  A boot that still
fails leaves its log in `/sys/fs/pstore/console-ramoops-0`; boot the working
`sm8150-fork` generation and read it there, which is what the pstore settings
above are for.

The rebase also needed three API updates that are folded into the patches: the
nabu panel init sequence passes the DSI multi-context by address (upstream has
that helper as a macro, the downstream tree had its own value-argument one),
the nt36523 touchscreen looks its GPIOs up with the gpiod consumer API
(`of_gpio.h` is gone), and ath10k includes `<linux/hex.h>` for `mac_pton()`.

## Adding a kernel

1. Create `pkgs/kernel/<name>/` with `default.nix`, `patches/` and `configs/`.
2. Regenerate the patches from the downstream tree you are rebasing (see the
   header of `mainline-latest/default.nix` for the workflow that was used).
3. Add one line to `default.nix` (the registry).  Everything else — the
   overlay (`pkgs.kernel-*`), the flake package `.#nabu-kernel-<name>`, the
   `nabu.kernel.name` option and the CI matrix — picks it up automatically.

## Required settings

Each kernel ships `configs/required-nabu.config`, a list of settings that must
be present verbatim in the resolved `.config`.  `postConfigure` greps for them,
so a kernel update or a patch rebase that silently drops a driver needed to
reach the root filesystem or to light the panel fails the build instead of
failing on the device.  Keep the file free of settings that kconfig may resolve
to the other value (`m` vs `y`).
