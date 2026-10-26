#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include "internal.h"

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

typedef struct context { int id, started; wump_chan *done; } context;
static _Thread_local context *active;
static atomic_int entered, freed, unstarted;
static __attribute__((noinline)) context *get_active(void) {
	__asm__ volatile("" ::: "memory");
	return active;
}

static void enter(void *arg) { active = arg; atomic_fetch_add(&entered, 1); }
static void cleanup(void *arg) {
	context *ctx = arg;
	CHECK(wump_self() == NULL);
	if (!ctx->started) atomic_fetch_add(&unstarted, 1);
	atomic_fetch_add(&freed, 1);
	free(ctx);
	active = NULL;
}

static void child(void *arg) {
	context *ctx = arg;
	CHECK(get_active() == ctx);
	ctx->started = 1;
	for (int i = 0; i < 100; i++) {
		wump_yield();
		CHECK(get_active() == ctx);
	}
	CHECK(wump_sleep(1000) == 0 && get_active() == ctx);
	CHECK(wump_syscall_enter() == 0);
	CHECK(wump_syscall_exit() == 0 && get_active() == ctx);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void program(void *arg) {
	int nprocs = *(int *)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	for (int i = 0; i < 32; i++) {
		context *ctx = calloc(1, sizeof(*ctx));
		CHECK(ctx != NULL);
		ctx->id = i;
		ctx->done = done;
		CHECK(wump_go_context(child, ctx, enter, cleanup) == 0);
	}
	for (int i = 0; i < 32; i++) CHECK(wump_chan_recv(done, NULL) == 1);
	(void)nprocs;
	wump_chan_free(done);
}

static void park(void *arg) {
	context *ctx = arg;
	ctx->started = 1;
	CHECK(wump_chan_recv(ctx->done, NULL) == 1);
}

static void abandon(void *arg) {
	wump_chan *ch = arg;
	for (int i = 0; i < 3; i++) {
		context *ctx = calloc(1, sizeof(*ctx));
		CHECK(ctx != NULL);
		ctx->done = ch;
		CHECK(wump_go_context(park, ctx, enter, cleanup) == 0);
		if (i < 2) wump_yield();
	}
}

static void halt_main(void *arg) {
	(void)arg;
	context *ctx = calloc(1, sizeof(*ctx));
	CHECK(ctx != NULL);
	ctx->started = 1;
	CHECK(wump_context_attach(NULL, cleanup, ctx) == -1);
	CHECK(wump_context_attach(enter, cleanup, ctx) == 0);
	CHECK(wump_context_attach(enter, cleanup, ctx) == -1 && errno == EBUSY);
	CHECK(wump_go_context(child, ctx, enter, NULL) == -1 && errno == EINVAL);
	wump_halt(EIO);
}

static void plain_child(void *arg) {
	CHECK(get_active() == NULL);
	CHECK(wump_chan_send(arg, NULL) == 0);
}

static void reuse(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	for (int i = 0; i < 20; i++) {
		context *ctx = calloc(1, sizeof(*ctx));
		CHECK(ctx != NULL);
		ctx->done = done;
		CHECK(wump_go_context(child, ctx, enter, cleanup) == 0);
		CHECK(wump_chan_recv(done, NULL) == 1);
		wump_yield(); /* Let the sender finish and recycle its mapping. */
		CHECK(wump_go(plain_child, done) == 0);
		CHECK(wump_chan_recv(done, NULL) == 1);
		wump_yield();
	}
	wump_chan_free(done);
}

int main(void) {
	CHECK(wump_context_attach(enter, cleanup, NULL) == -1 && errno == EINVAL);
	for (int n = 1; n <= 4; n *= 4) {
		CHECK(wump_run(program, &n, n) == 0);
	}
	CHECK(atomic_load(&freed) == 64 && atomic_load(&entered) >= 64 * 100);
	wump_chan *ch = wump_chan_make(0, 0);
	CHECK(ch != NULL && wump_run(abandon, ch, 1) == 0);
	wump_chan_free(ch);
	CHECK(atomic_load(&freed) == 67 && atomic_load(&unstarted) == 1);
	CHECK(wump_run(halt_main, NULL, 1) == -1 && errno == EIO);
	CHECK(atomic_load(&freed) == 68);
	CHECK(wump_run(reuse, NULL, 1) == 0);
	CHECK(atomic_load(&freed) == 88);
	puts("ok - context hooks follow migration, survive native handoff, and clean up completed, parked, and unstarted tasks");
	return 0;
}
