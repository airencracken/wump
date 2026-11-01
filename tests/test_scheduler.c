#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "internal.h"

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

/* Probe only the caller's native thread. Other Ms can still be finishing
 * syscall-exit bookkeeping. No marked native call spans a measurement. */
static _Thread_local int measuring;
static _Thread_local unsigned mutex_calls, signals, clocks;
/* A solitary yielding task can migrate. Count notifications across all Ms,
 * rather than treating a native thread's counters as act-owned state. */
static atomic_int solitary_measuring;
static atomic_uint solitary_signals;

int __real_pthread_mutex_lock(pthread_mutex_t *);
int __wrap_pthread_mutex_lock(pthread_mutex_t *mu) {
	if (measuring) mutex_calls++;
	return __real_pthread_mutex_lock(mu);
}

int __real_pthread_cond_signal(pthread_cond_t *);
int __wrap_pthread_cond_signal(pthread_cond_t *cond) {
	if (measuring) signals++;
	if (atomic_load_explicit(&solitary_measuring, memory_order_acquire))
		atomic_fetch_add_explicit(&solitary_signals, 1, memory_order_relaxed);
	return __real_pthread_cond_signal(cond);
}

static void native_noop(void *arg) { (void)arg; }
static void publish_completed(void *arg) {
	atomic_store_explicit((atomic_uint *)arg, 1, memory_order_release);
}

typedef struct solitary_context {
	atomic_uint entries, cleanups;
} solitary_context;

static void solitary_enter(void *arg) {
	solitary_context *ctx = arg;
	atomic_fetch_add_explicit(&ctx->entries, 1, memory_order_relaxed);
}

static void solitary_cleanup(void *arg) {
	solitary_context *ctx = arg;
	atomic_fetch_add_explicit(&ctx->cleanups, 1, memory_order_relaxed);
}

static void solitary(void *arg) {
	solitary_context *ctx = arg;
	CHECK(wump_context_attach(solitary_enter, solitary_cleanup, ctx) == 0);
	for (int phase = 0; phase < 2; phase++) {
		unsigned before = atomic_load_explicit(&ctx->entries, memory_order_relaxed);
		atomic_store_explicit(&solitary_signals, 0, memory_order_relaxed);
		atomic_store_explicit(&solitary_measuring, 1, memory_order_release);
		for (int i = 0; i < 256; i++) {
			wump_set_errno(1234 + i);
			wump_yield();
			CHECK(wump_errno() == 1234 + i);
			CHECK(wump_worker_id() >= 0);
		}
		atomic_store_explicit(&solitary_measuring, 0, memory_order_release);
		CHECK(atomic_load_explicit(&solitary_signals, memory_order_relaxed) == 0);
		CHECK(atomic_load_explicit(&ctx->entries, memory_order_relaxed) == before + 256);
		if (phase == 0) CHECK(wump_blocking(native_noop, NULL) == 0);
	}
	if (wump_nprocs() > 1) {
		/* This call cannot suspend its caller, so native TLS is stable.
		 * New work must still advertise even when it is the only queued job. */
		atomic_uint finished = ATOMIC_VAR_INIT(0);
		signals = 0;
		measuring = 1;
		CHECK(wump_go(publish_completed, &finished) == 0);
		measuring = 0;
		CHECK(signals != 0);
		while (!atomic_load_explicit(&finished, memory_order_acquire)) wump_yield();
	}
}

int __real_clock_gettime(clockid_t, struct timespec *);
int __wrap_clock_gettime(clockid_t clock, struct timespec *now) {
	if (measuring) clocks++;
	return __real_clock_gettime(clock, now);
}

static __attribute__((noinline)) void begin_probe(void) {
	__asm__ volatile("" ::: "memory");
	mutex_calls = signals = clocks = 0;
	measuring = 1;
}

static __attribute__((noinline)) unsigned end_probe(unsigned maximum_locks) {
	/* Reselect native TLS after any scheduling in the caller. */
	__asm__ volatile("" ::: "memory");
	measuring = 0;
	CHECK(mutex_calls <= maximum_locks && signals == 0);
	return clocks;
}

static void completed(void *arg) {
	(*(unsigned *)arg)++;
}

static void exercise(void *arg) {
	(void)arg;
	CHECK(wump_nprocs() == 1 && wump_worker_id() == 0);
	unsigned count = 0;
	/* Let the first child return so its mapped stack is available for reuse.
	 * The measured spawns should need neither allocation nor shared queues. */
	CHECK(wump_go(completed, &count) == 0);
	wump_yield();
	CHECK(count == 1);
	for (int phase = 0; phase < 2; phase++) {
		for (int i = 0; i < 256; i++) {
			begin_probe();
			int result = wump_go(completed, &count);
			CHECK(end_probe(0) == 0);
			CHECK(result == 0);
			wump_yield();
			CHECK(count == 2 + (unsigned)(phase * 256 + i));
		}
		if (phase == 0) {
			/* A P can change native owners even with one slot. Queue ownership
			 * follows the donated P, never an assumed permanent pthread. */
			CHECK(wump_blocking(native_noop, NULL) == 0);
			CHECK(wump_worker_id() == 0);
		}
	}
	/* No remaining children or native calls can migrate this probe. Yield
	 * still enters the scheduler for shutdown/timer checks, but should not
	 * signal another scheduler or lock its private local queue. A periodic
	 * global-queue poll can add one mutex acquisition. */
	unsigned clock_reads = 0;
	for (int i = 0; i < 256; i++) {
		begin_probe();
		wump_yield();
		clock_reads += end_probe(2);
	}
	CHECK(clock_reads <= 5);
}

int main(void) {
	for (int i = 0; i < 4; i++) CHECK(wump_run(exercise, NULL, 1) == 0);
	for (int repeat = 0; repeat < 4; repeat++) {
		for (int slots = 1; slots <= 4; slots *= 2) {
			solitary_context ctx = { .entries = ATOMIC_VAR_INIT(0), .cleanups = ATOMIC_VAR_INIT(0) };
			CHECK(wump_run(solitary, &ctx, slots) == 0);
			CHECK(atomic_load_explicit(&ctx.cleanups, memory_order_relaxed) == 1);
		}
	}
	puts("ok - one-slot cached spawn and local dispatch avoid shared coordination and per-dispatch clock reads before and after native handoff");
	puts("ok - solitary yields on one/two/four slots avoid notifications, preserve errno and dispatch hooks, and survive native handoff");
	return 0;
}
