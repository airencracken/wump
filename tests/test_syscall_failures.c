#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "wump.h"

extern int wump_test_get_errno(void);
#define CHECK(expr) do { if (!(expr)) { \
	fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, wump_test_get_errno()); abort(); \
} } while (0)

enum operation { NONE, ALLOC, COND, THREAD };
static atomic_int failure;
static atomic_int created, joined, conditions;
static atomic_int observe_shutdown, shutdown_seen, monitor_started, cancellation_seen;

static int fail(enum operation op) {
	int expected = op;
	return atomic_compare_exchange_strong(&failure, &expected, NONE);
}

void *__real_calloc(size_t, size_t);
void *__wrap_calloc(size_t n, size_t size) {
	if (fail(ALLOC)) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_calloc(n, size);
}
int __real_pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int __wrap_pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr) {
	if (fail(COND)) {
		return ENOMEM;
	}
	int result = __real_pthread_cond_init(cond, attr);
	if (result == 0) {
		atomic_fetch_add(&conditions, 1);
	}
	return result;
}
int __real_pthread_cond_destroy(pthread_cond_t *);
int __wrap_pthread_cond_destroy(pthread_cond_t *cond) {
	int result = __real_pthread_cond_destroy(cond);
	if (result == 0) {
		CHECK(atomic_fetch_sub(&conditions, 1) > 0);
	}
	return result;
}
int __real_pthread_cond_broadcast(pthread_cond_t *);
int __wrap_pthread_cond_broadcast(pthread_cond_t *cond) {
	/* Stop publishes its flag before broadcasting work. Observing that
	 * boundary makes the concurrent-enter shutdown test deterministic. */
	if (atomic_load(&observe_shutdown)) {
		atomic_store(&shutdown_seen, 1);
	}
	return __real_pthread_cond_broadcast(cond);
}
int __real_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*fn)(void *), void *arg) {
	if (fail(THREAD)) {
		return EAGAIN;
	}
	int result = __real_pthread_create(thread, attr, fn, arg);
	if (result == 0) {
		atomic_fetch_add(&created, 1);
	}
	return result;
}
int __real_pthread_join(pthread_t, void **);
int __wrap_pthread_join(pthread_t thread, void **arg) {
	int result = __real_pthread_join(thread, arg);
	if (result == 0) {
		atomic_fetch_add(&joined, 1);
	}
	return result;
}

static void count_call(void *arg) { (*(int *)arg)++; }

static void signal_done(void *arg) {
	CHECK(wump_chan_send(arg, NULL) == 0);
}

static void failure_program(void *arg) {
	enum operation op = *(enum operation *)arg;
	pthread_t original = pthread_self();
	int expected = op == THREAD ? EAGAIN : ENOMEM;
	int base_threads = atomic_load(&created);
	int base_conditions = atomic_load(&conditions);
	atomic_store(&failure, op);
	CHECK(wump_syscall_enter() == -1 && wump_test_get_errno() == expected);
	CHECK(atomic_load(&failure) == NONE);
	CHECK(pthread_equal(original, pthread_self()) && wump_worker_id() == 0);
	CHECK(atomic_load(&created) == base_threads && atomic_load(&conditions) == base_conditions);
	int calls = 0;
	atomic_store(&failure, op);
	CHECK(wump_blocking(count_call, &calls) == -1 && wump_test_get_errno() == expected);
	CHECK(calls == 0 && wump_worker_id() == 0);
	CHECK(atomic_load(&created) == base_threads && atomic_load(&conditions) == base_conditions);
	CHECK(wump_blocking(count_call, &calls) == 0 && calls == 1);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	CHECK(wump_go(signal_done, done) == 0);
	CHECK(wump_chan_recv(done, NULL) == 1);
	wump_chan_free(done);
}

typedef struct deadlock_arg { enum operation op; wump_chan *ch; } deadlock_arg;

static void failure_deadlock(void *arg) {
	deadlock_arg *ctx = arg;
	atomic_store(&failure, ctx->op);
	CHECK(wump_syscall_enter() == -1);
	CHECK(wump_chan_recv(ctx->ch, NULL) == 1);
}

static void cache_program(void *arg) {
	(void)arg;
	int before = atomic_load(&created);
	int calls = 0;
	CHECK(wump_blocking(count_call, &calls) == 0 && calls == 1);
	CHECK(atomic_load(&created) == before + 1);
	/* Every completed handoff publishes an idle M before its task can
	 * run again. Even a thread-create failure must remain unconsumed. */
	atomic_store(&failure, THREAD);
	for (int i = 0; i < 1000; i++) {
		CHECK(wump_blocking(count_call, &calls) == 0);
	}
	CHECK(calls == 1001 && atomic_load(&created) == before + 1);
	CHECK(atomic_load(&failure) == THREAD);
	atomic_store(&failure, NONE);
}

static void shutdown_monitor(void *arg) {
	(void)arg;
	atomic_store(&monitor_started, 1);
	while (!atomic_load(&shutdown_seen)) {
		sched_yield();
	}
	int calls = 0;
	CHECK(wump_syscall_enter() == -1 && wump_test_get_errno() == ECANCELED);
	CHECK(wump_blocking(count_call, &calls) == -1 && wump_test_get_errno() == ECANCELED);
	CHECK(calls == 0 && wump_worker_id() >= 0);
	atomic_store(&cancellation_seen, 1);
}

static void shutdown_program(void *arg) {
	(void)arg;
	CHECK(wump_go(shutdown_monitor, NULL) == 0);
	while (!atomic_load(&monitor_started)) {
		wump_yield();
	}
}

int main(void) {
	alarm(60);
	enum operation ops[] = { ALLOC, COND, THREAD };
	for (size_t i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
		CHECK(wump_run(failure_program, &ops[i], 1) == 0);
		CHECK(atomic_load(&created) == atomic_load(&joined));
		CHECK(atomic_load(&conditions) == 0);
		deadlock_arg ctx = { ops[i], wump_chan_make(0, 0) };
		CHECK(ctx.ch != NULL);
		CHECK(wump_run(failure_deadlock, &ctx, 1) == -1 && wump_test_get_errno() == EDEADLK);
		wump_chan_free(ctx.ch);
		CHECK(atomic_load(&created) == atomic_load(&joined));
		CHECK(atomic_load(&conditions) == 0);
	}
	puts("ok - failed replacement setup retains its slot, skips callbacks, and leaves no false liveness");
	CHECK(wump_run(cache_program, NULL, 1) == 0);
	CHECK(atomic_load(&created) == atomic_load(&joined));
	CHECK(atomic_load(&conditions) == 0);
	puts("ok - completed native threads are reused and all conditions/threads are reclaimed");
	atomic_store(&observe_shutdown, 1);
	CHECK(wump_run(shutdown_program, NULL, 2) == 0);
	atomic_store(&observe_shutdown, 0);
	CHECK(atomic_load(&cancellation_seen) == 1);
	CHECK(atomic_load(&created) == atomic_load(&joined));
	CHECK(atomic_load(&conditions) == 0);
	puts("ok - shutdown rejects new handoffs before the machine list is joined");
	return 0;
}
