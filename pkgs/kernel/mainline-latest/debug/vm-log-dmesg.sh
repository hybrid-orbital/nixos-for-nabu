# Debug-only instrumentation, run by msm-module.nix inside the kernel tree
# (`extraShell`), not part of the kernel package and not for upstream.
#
# It makes the driver print every VM map/unmap operation - with the reason
# string ("map", "unmap", "evict", "purge", "free", ...) and the submitqueue id
# - to dmesg when the module is loaded with msm.vm_log_dmesg=1.
#
# Why: a `*** gpu fault: ... iova=... source=CCU` line only says that some VA
# had no valid PTE at that moment.  To find out *who* removed the mapping, the
# VM operation log has to be visible while it happens; the driver keeps that log
# in vm->log but only dumps it when a VM is marked unusable, which a SMMU fault
# does not do.

set -e

file=drivers/gpu/drm/msm/msm_gem_vma.c

python3 - "$file" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

anchor = 'module_param_named(vm_log_shift, vm_log_shift, uint, 0600);\n'
assert src.count(anchor) == 1, "vm_log_shift parameter not found"
src = src.replace(anchor, anchor + '''
/*
 * Debug aid: print every VM map/unmap operation to dmesg, so that a GPU fault
 * can be correlated with the unmap that removed the mapping it read from.
 */
static bool vm_log_dmesg = false;
MODULE_PARM_DESC(vm_log_dmesg, "Log VM map/unmap operations to dmesg");
module_param_named(vm_log_dmesg, vm_log_dmesg, bool, 0600);
''')

anchor = '\tvm_dbg("%s:%p:%d: %016llx %016llx", op, vm, queue_id, iova, iova + range);\n'
assert src.count(anchor) == 1, "vm_dbg call in vm_log() not found"
src = src.replace(anchor, anchor + '''
\tif (vm_log_dmesg)
\t\tpr_info("msm-vm %s: %016llx-%016llx queue %d\\n",
\t\t\top, iova, iova + range, queue_id);
''')

open(path, "w").write(src)
PY

grep -q 'vm_log_dmesg' "$file"
echo ">>> vm_log_dmesg instrumentation added to $file"
