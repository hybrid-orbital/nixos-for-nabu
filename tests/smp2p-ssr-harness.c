/* Minimal list/SMEM stubs for the kernel's unmodified SSR helper. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define BIT(n) (1U << (n))
#define SMP2P_FLAGS_RESTART_DONE_BIT 0
struct smp2p_entry {
	uint32_t *value;
	uint32_t last_value;
	struct smp2p_entry *next;
};
struct smp2p_smem_item { uint32_t flags; };
struct qcom_smp2p {
	struct smp2p_smem_item *in;
	struct smp2p_entry *inbound;
	bool ssr_ack_enabled;
	bool ssr_ack;
};
#define list_for_each_entry(entry, head, node) \
	for ((entry) = *(head); (entry); (entry) = (entry)->next)
#include "ssr-under-test.h"

int main(void)
{
	uint32_t ready_handover = 6, other_value = 8;
	struct smp2p_entry absent = { .last_value = 0xdead };
	struct smp2p_entry other = {
		.value = &other_value, .last_value = 8, .next = &absent,
	};
	struct smp2p_entry slpi = {
		.value = &ready_handover, .last_value = 6, .next = &other,
	};
	struct smp2p_smem_item in = { 0 };
	struct qcom_smp2p smp2p = {
		.in = &in, .inbound = &slpi, .ssr_ack_enabled = true,
	};

	/* A steady slave-kernel == 6 must not fabricate ready/handover edges. */
	for (int i = 0; i < 100; i++) {
		assert(!qcom_smp2p_check_ssr(&smp2p));
		assert(slpi.last_value == 6);
		assert(other.last_value == 8);
	}

	/* Both restart flag polarities must replay asserted bits once. */
	for (int i = 0; i < 2; i++) {
		in.flags ^= BIT(SMP2P_FLAGS_RESTART_DONE_BIT);
		assert(qcom_smp2p_check_ssr(&smp2p));
		assert(slpi.last_value == 0 && other.last_value == 0);
		assert(absent.last_value == 0xdead);
		/* Model notify_in() consuming the values, followed by SSR ack. */
		slpi.last_value = ready_handover;
		other.last_value = other_value;
		smp2p.ssr_ack = !smp2p.ssr_ack;
		assert(!qcom_smp2p_check_ssr(&smp2p));
		assert(slpi.last_value == 6 && other.last_value == 8);
	}

	/* No reset before SSR acknowledgement support is negotiated. */
	smp2p.ssr_ack_enabled = false;
	in.flags ^= BIT(SMP2P_FLAGS_RESTART_DONE_BIT);
	assert(!qcom_smp2p_check_ssr(&smp2p));
	assert(slpi.last_value == 6 && other.last_value == 8);
	puts("SMP2P: steady notifications and both SSR transitions passed");
	return 0;
}
