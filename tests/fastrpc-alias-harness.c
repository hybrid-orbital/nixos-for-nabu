/* Fault-injection harness for the actual helper extracted from each patch.
 * This checks address arithmetic and rollback, not real ARM SMMU behavior.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
typedef uint64_t u64;
typedef uint64_t dma_addr_t;
typedef uint64_t phys_addr_t;
#define PAGE_SIZE 4096ULL
#define BIT_ULL(n) (1ULL << (n))
#define DMA_BIT_MASK(n) (BIT_ULL(n) - 1)
#define IS_ALIGNED(x, a) (!((x) & ((a) - 1)))
#define PAGE_ALIGN(x) (((x) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1))
#define check_add_overflow(a, b, out) __builtin_add_overflow(a, b, out)
#define WARN_ON(x) assert(!(x))
#define IOMMU_READ 1
#define IOMMU_WRITE 2
#define IOMMU_CACHE 4
#define GFP_KERNEL 0
struct iommu_domain {
    u64 pgsize_bitmap;
    struct { bool force_aperture; u64 aperture_start, aperture_end; } geometry;
    bool dma;
};
struct device { struct iommu_domain *domain; u64 mask; bool coherent; };
struct fastrpc_alias { struct iommu_domain *domain; dma_addr_t iova; size_t size; };
static u64 low, high, aliases[4];
static int map_calls, fail_at, last_prot;
static size_t unmapped;
static struct iommu_domain *iommu_get_domain_for_dev(struct device *d) { return d->domain; }
static bool iommu_is_dma_domain(struct iommu_domain *d) { return d->dma; }
static u64 dma_get_mask(struct device *d) { return d->mask; }
static bool dev_is_dma_coherent(struct device *d) { return d->coherent; }
static phys_addr_t iommu_iova_to_phys(struct iommu_domain *d, u64 addr)
{
    (void)d;
    if (addr >= low && addr < low + 3 * PAGE_SIZE)
        return 0x80000000ULL + (addr - low) * 2; /* discontiguous backing pages */
    if (addr >= high && addr < high + 4 * PAGE_SIZE)
        return aliases[(addr - high) / PAGE_SIZE];
    return 0;
}
static int iommu_map(struct iommu_domain *d, u64 addr, u64 phys, size_t size, int prot, int gfp)
{
    (void)d; (void)gfp;
    assert(size == PAGE_SIZE);
    if (map_calls++ == fail_at) return -ENOMEM;
    assert(addr >= high && addr < high + sizeof(aliases) / sizeof(aliases[0]) * PAGE_SIZE);
    assert(!aliases[(addr - high) / PAGE_SIZE]);
    aliases[(addr - high) / PAGE_SIZE] = phys;
    last_prot = prot;
    return 0;
}
static size_t iommu_unmap(struct iommu_domain *d, u64 addr, size_t size)
{
    (void)d;
    for (size_t i = 0; i < size; i += PAGE_SIZE) {
        assert(aliases[(addr + i - high) / PAGE_SIZE]);
        aliases[(addr + i - high) / PAGE_SIZE] = 0;
    }
    unmapped += size;
    return size;
}
#include "alias-under-test.h"
static void reset(void)
{
    low = 0xffffd000ULL;
    high = low + BIT_ULL(32);
    memset(aliases, 0, sizeof(aliases));
    map_calls = 0; fail_at = -1; unmapped = 0;
}
int main(void)
{
    struct iommu_domain domain = { PAGE_SIZE, { true, 0, BIT_ULL(36) - 1 }, true };
    struct device dev = { &domain, DMA_BIT_MASK(32), true };
    struct fastrpc_alias a = {0};
    reset();
    assert(!fastrpc_alias_map(&dev, low, 3 * PAGE_SIZE, BIT_ULL(32), &a));
    assert(a.iova == high && a.size == 3 * PAGE_SIZE);
    assert(aliases[2] == 0x80004000ULL && (last_prot & IOMMU_CACHE));
    fastrpc_alias_unmap(&a);
    fastrpc_alias_unmap(&a);
    assert(unmapped == 3 * PAGE_SIZE);
    reset(); fail_at = 1;
    assert(fastrpc_alias_map(&dev, low, 3 * PAGE_SIZE, BIT_ULL(32), &a) == -ENOMEM);
    assert(a.size == 0 && unmapped == PAGE_SIZE && !aliases[0]);
    reset(); aliases[1] = 0x90000000;
    assert(fastrpc_alias_map(&dev, low, 3 * PAGE_SIZE, BIT_ULL(32), &a) == -EEXIST);
    assert(!aliases[0] && aliases[1] == 0x90000000 && unmapped == PAGE_SIZE);
    reset();
    assert(fastrpc_alias_map(&dev, low, 4 * PAGE_SIZE, BIT_ULL(32), &a) == -EOVERFLOW);
    assert(fastrpc_alias_map(&dev, low + 1, PAGE_SIZE, BIT_ULL(32), &a) == -EINVAL);
    assert(fastrpc_alias_map(&dev, low, 0, BIT_ULL(32), &a) == -EINVAL);
    assert(fastrpc_alias_map(&dev, low, PAGE_SIZE, UINT64_MAX & ~DMA_BIT_MASK(32), &a) == -ERANGE);
    domain.geometry.aperture_end = DMA_BIT_MASK(32);
    assert(fastrpc_alias_map(&dev, low, PAGE_SIZE, BIT_ULL(32), &a) == -ERANGE);
    assert(map_calls == 0);
    domain.geometry.aperture_end = BIT_ULL(36) - 1;
    dev.mask = DMA_BIT_MASK(36);
    assert(fastrpc_alias_map(&dev, low, PAGE_SIZE, BIT_ULL(32), &a) == -EOPNOTSUPP);
    dev.mask = DMA_BIT_MASK(32); dev.domain = NULL;
    assert(fastrpc_alias_map(&dev, low, PAGE_SIZE, BIT_ULL(32), &a) == -EOPNOTSUPP);
    dev.domain = &domain; dev.coherent = false;
    reset(); low -= PAGE_SIZE; high = low + BIT_ULL(32);
    assert(fastrpc_alias_map(&dev, low, 4 * PAGE_SIZE, BIT_ULL(32), &a) == -EFAULT);
    assert(unmapped == 3 * PAGE_SIZE && a.size == 0);
    reset();
    assert(!fastrpc_alias_map(&dev, low, 1, BIT_ULL(32), &a));
    assert(a.size == PAGE_SIZE && !(last_prot & IOMMU_CACHE));
    fastrpc_alias_unmap(&a);
    puts("FastRPC alias arithmetic / rollback tests passed");
}
