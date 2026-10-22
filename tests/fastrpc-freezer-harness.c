/* Native control-flow test, not a simulation of the kernel scheduler. */
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

#define ERESTARTSYS 512
#define TASK_INTERRUPTIBLE 1
#define TASK_FREEZABLE 0x2000
struct completion { int unused; };
static struct completion original;
static int results[4], freezes[4], waits, freeze_calls;

static int wait_for_completion_state(struct completion *work, unsigned int state)
{
	assert(work == &original); /* Never switch to a new request. */
	assert(state == (TASK_INTERRUPTIBLE | TASK_FREEZABLE));
	assert(waits < 4);
	return results[waits++];
}

static bool try_to_freeze(void)
{
	assert(freeze_calls < 4);
	return freezes[freeze_calls++];
}

#include "wait-under-test.h"

static void reset(void)
{
	waits = freeze_calls = 0;
	for (int i = 0; i < 4; ++i)
		results[i] = freezes[i] = 0;
}

int main(void)
{
	reset();
	assert(fastrpc_wait_for_user_completion(&original) == 0);
	assert(waits == 1 && freeze_calls == 0);

	/* Freeze arrives before the freezable sleep is established; twice. */
	reset();
	results[0] = results[1] = -ERESTARTSYS;
	freezes[0] = freezes[1] = 1;
	assert(fastrpc_wait_for_user_completion(&original) == 0);
	assert(waits == 3 && freeze_calls == 2);

	/* A real signal remains interruptible, including after thaw. */
	reset();
	results[0] = -ERESTARTSYS;
	assert(fastrpc_wait_for_user_completion(&original) == -ERESTARTSYS);
	assert(waits == 1 && freeze_calls == 1);
	reset();
	results[0] = results[1] = -ERESTARTSYS;
	freezes[0] = 1;
	assert(fastrpc_wait_for_user_completion(&original) == -ERESTARTSYS);
	assert(waits == 2 && freeze_calls == 2);

	puts("FastRPC freezer wait: completion, repeated freeze and real signals passed");
}
