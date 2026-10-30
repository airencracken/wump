#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sanitizer/msan_interface.h>
#include "wump.h"

#ifndef __has_feature
#define __has_feature(feature) 0
#endif
#if !__has_feature(memory_sanitizer)
#error "Build this control with MemorySanitizer"
#endif

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static __attribute__((noinline)) unsigned touch(volatile unsigned char *bytes) { return *bytes; }

static void initialized(void *arg) {
	wump_chan *done = arg;
	volatile unsigned char bytes[64] = {19};
	for (int i = 0; i < 100; i++) {
		wump_yield();
		if (i % 10 == 0) {
			CHECK(wump_syscall_enter() == 0);
			CHECK(wump_syscall_exit() == 0);
		}
		CHECK(touch(bytes) == 19);
		__msan_check_mem_is_initialized((const void *)bytes, sizeof(bytes));
	}
	CHECK(wump_chan_send(done, NULL) == 0);
}

static void positive(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	/* Sequential batches also exercise recycled coroutine stacks. */
	for (int batch = 0; batch < 2; batch++) {
		for (int i = 0; i < 8; i++) CHECK(wump_go(initialized, done) == 0);
		for (int i = 0; i < 8; i++) CHECK(wump_chan_recv(done, NULL) == 1);
	}
	wump_chan_free(done);
}

static void heap_error(void *arg) {
	(void)arg;
	volatile unsigned char *bytes = malloc(8);
	CHECK(bytes != NULL);
	wump_yield();
	CHECK(touch(bytes) == 19);
	free((void *)bytes);
}

static void stack_error(void *arg) {
	(void)arg;
	volatile unsigned char bytes[64];
	wump_yield();
	CHECK(wump_syscall_enter() == 0);
	CHECK(wump_syscall_exit() == 0);
	CHECK(touch(bytes) == 19);
}

typedef struct transfer { wump_chan *data, *done; } transfer;

static void channel_reader(void *arg) {
	transfer *channels = arg;
	unsigned char byte;
	CHECK(wump_chan_recv(channels->data, &byte) == 1);
	wump_yield();
	CHECK(touch(&byte) == 19);
	CHECK(wump_chan_send(channels->done, NULL) == 0);
}

static void channel_error(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(1, 1);
	CHECK(ch != NULL);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	transfer channels = {.data = ch, .done = done};
	unsigned char *byte = malloc(1);
	CHECK(byte != NULL);
	/* memcpy may propagate poisoned bytes; the receiving act must still
	 * diagnose their use after the sender's allocation has been freed. */
	CHECK(wump_chan_send(ch, byte) == 0);
	free(byte);
	CHECK(wump_go(channel_reader, &channels) == 0);
	CHECK(wump_chan_recv(done, NULL) == 1);
	wump_chan_free(ch);
	wump_chan_free(done);
}

int main(int argc, char **argv) {
	CHECK(__msan_get_track_origins() == 2);
	if (argc == 1) {
		for (int slots = 1; slots <= 4; slots *= 2) CHECK(wump_run(positive, NULL, slots) == 0);
		puts("ok - MSan accepts initialized coroutine stacks across yields, reuse and native handoff");
		return 0;
	}
	CHECK(argc == 2);
	wump_fn fn = NULL;
	if (strcmp(argv[1], "heap") == 0) fn = heap_error;
	else if (strcmp(argv[1], "stack") == 0) fn = stack_error;
	else if (strcmp(argv[1], "channel") == 0) fn = channel_error;
	CHECK(fn != NULL && wump_run(fn, NULL, 1) == 0);
	return 0;
}
