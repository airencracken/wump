#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "internal.h"

#ifndef WUMP_ASAN
#error "Build this control with AddressSanitizer"
#endif

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static void *native_fake;
static volatile unsigned char *escaped;
static __attribute__((noinline)) unsigned touch(volatile unsigned char *p) { return *p; }
static __attribute__((noinline)) void retain(volatile unsigned char *p) { escaped = p; }
static __attribute__((noinline)) void release(void *p) { free(p); }

typedef struct fiber_arg {
	wump_chan *done;
	void *fake;
} fiber_arg;

static void private_stack(void *arg) {
	fiber_arg *ctx = arg;
	volatile unsigned char bytes[64] = {19};
	ctx->fake = __asan_get_current_fake_stack();
	CHECK(ctx->fake != NULL && ctx->fake != native_fake);
	for (int i = 0; i < 100; i++) {
		wump_yield();
		if (i % 10 == 0) {
			CHECK(wump_syscall_enter() == 0);
			CHECK(wump_syscall_exit() == 0);
		}
		CHECK(touch(bytes) == 19 && __asan_get_current_fake_stack() == ctx->fake);
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void positive(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	fiber_arg tasks[2] = {{.done = done}, {.done = done}};
	for (int i = 0; i < 2; i++) CHECK(wump_go(private_stack, &tasks[i]) == 0);
	for (int i = 0; i < 2; i++) CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(tasks[0].fake != tasks[1].fake);
	wump_chan_free(done);
}

static void heap_error(void *arg) {
	(void)arg;
	volatile unsigned char *p = malloc(8);
	CHECK(p != NULL);
	release((void *)p);
	wump_yield();
	p[0] = 7;
}

static void stack_error(void *arg) {
	(void)arg;
	volatile size_t index = 32;
	volatile unsigned char bytes[32] = {1};
	CHECK(touch(bytes) == 1);
	wump_yield();
	bytes[index] = 7;
	CHECK(touch(bytes) == 1);
}

static __attribute__((noinline)) void returning_frame(void) {
	volatile unsigned char bytes[32] = {1};
	retain(bytes);
	CHECK(touch(bytes) == 1);
}

static void return_error(void *arg) {
	(void)arg;
	returning_frame();
	wump_yield();
	escaped[0] = 7;
}

static void leak_error(void *arg) {
	(void)arg;
	void *p = malloc(123);
	CHECK(p != NULL);
	__asm__ volatile("" : : "r"(p) : "memory");
}

int main(int argc, char **argv) {
	volatile unsigned char bytes[64] = {1};
	native_fake = __asan_get_current_fake_stack();
	CHECK(native_fake != NULL && touch(bytes) == 1);
	if (argc == 1) {
		for (int n = 1; n <= 4; n *= 4) CHECK(wump_run(positive, NULL, n) == 0);
		CHECK(__asan_get_current_fake_stack() == native_fake && touch(bytes) == 1);
		puts("ok - ASan tracks private fake stacks across migration and native handoff");
		return 0;
	}
	CHECK(argc == 2);
	wump_fn fn = NULL;
	if (strcmp(argv[1], "heap") == 0) fn = heap_error;
	else if (strcmp(argv[1], "stack") == 0) fn = stack_error;
	else if (strcmp(argv[1], "return") == 0) fn = return_error;
	else if (strcmp(argv[1], "leak") == 0) fn = leak_error;
	CHECK(fn != NULL && wump_run(fn, NULL, 1) == 0);
	return 0;
}
