#include <stdatomic.h>
#include <stdlib.h>

#include "wump.h"

static atomic_int started;
static volatile int shared;

static void racer(void *arg) {
	atomic_fetch_add(&started, 1);
	while (atomic_load(&started) != 4) {
		__asm__ volatile("pause");
	}
	for (int i = 0; i < 10000; i++) {
		shared++; /* Deliberate race: this positive control must fail. */
	}
	if (wump_chan_send(arg, NULL) != 0) {
		abort();
	}
}

static void program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	if (done == NULL) {
		abort();
	}
	for (int i = 0; i < 4; i++) {
		if (wump_go(racer, done) != 0) {
			abort();
		}
	}
	for (int i = 0; i < 4; i++) {
		if (wump_chan_recv(done, NULL) != 1) {
			abort();
		}
	}
	wump_chan_free(done);
}

int main(void) {
	return wump_run(program, NULL, 4) == 0 ? 0 : 1;
}
