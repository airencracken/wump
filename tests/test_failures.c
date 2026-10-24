#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

#include "wump.h"

#define CHECK(expr) do { \
	if (!(expr)) { \
		fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, errno); \
		abort(); \
	} \
} while (0)

enum operation { NONE, MUTEX, COND, ATTR, CLOCK, ALIGNED, MAP, PROTECT, THREAD, MALLOC, CALLOC, REALLOC };
static enum operation failure;
static int countdown;
static int mappings, threads, main_calls;

static int should_fail(enum operation op) {
	if (failure == op && --countdown == 0) {
		failure = NONE;
		return 1;
	}
	return 0;
}

int __real_pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int __wrap_pthread_mutex_init(pthread_mutex_t *mu, const pthread_mutexattr_t *attr) {
	return should_fail(MUTEX) ? ENOMEM : __real_pthread_mutex_init(mu, attr);
}

int __real_pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int __wrap_pthread_cond_init(pthread_cond_t *cv, const pthread_condattr_t *attr) {
	return should_fail(COND) ? ENOMEM : __real_pthread_cond_init(cv, attr);
}

int __real_pthread_condattr_init(pthread_condattr_t *);
int __wrap_pthread_condattr_init(pthread_condattr_t *attr) {
	return should_fail(ATTR) ? ENOMEM : __real_pthread_condattr_init(attr);
}

int __real_pthread_condattr_setclock(pthread_condattr_t *, clockid_t);
int __wrap_pthread_condattr_setclock(pthread_condattr_t *attr, clockid_t clock) {
	return should_fail(CLOCK) ? EINVAL : __real_pthread_condattr_setclock(attr, clock);
}

int __real_posix_memalign(void **, size_t, size_t);
int __wrap_posix_memalign(void **ptr, size_t alignment, size_t size) {
	return should_fail(ALIGNED) ? ENOMEM : __real_posix_memalign(ptr, alignment, size);
}

void *__real_mmap(void *, size_t, int, int, int, off_t);
void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
	if (should_fail(MAP)) {
		errno = ENOMEM;
		return MAP_FAILED;
	}
	void *map = __real_mmap(addr, len, prot, flags, fd, offset);
	if (map != MAP_FAILED) {
		mappings++;
	}
	return map;
}

int __real_munmap(void *, size_t);
int __wrap_munmap(void *addr, size_t len) {
	int result = __real_munmap(addr, len);
	if (result == 0) {
		mappings--;
	}
	return result;
}

int __real_mprotect(void *, size_t, int);
int __wrap_mprotect(void *addr, size_t len, int prot) {
	if (should_fail(PROTECT)) {
		errno = EACCES;
		return -1;
	}
	return __real_mprotect(addr, len, prot);
}

int __real_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
	void *(*fn)(void *), void *arg) {
	if (should_fail(THREAD)) {
		return EAGAIN;
	}
	int result = __real_pthread_create(thread, attr, fn, arg);
	if (result == 0) {
		threads++;
	}
	return result;
}

int __real_pthread_join(pthread_t, void **);
int __wrap_pthread_join(pthread_t thread, void **value) {
	int result = __real_pthread_join(thread, value);
	if (result == 0) {
		threads--;
	}
	return result;
}

void *__real_malloc(size_t);
void *__wrap_malloc(size_t size) {
	if (should_fail(MALLOC)) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_malloc(size);
}

void *__real_calloc(size_t, size_t);
void *__wrap_calloc(size_t count, size_t size) {
	if (should_fail(CALLOC)) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_calloc(count, size);
}

void *__real_realloc(void *, size_t);
void *__wrap_realloc(void *ptr, size_t size) {
	if (should_fail(REALLOC)) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_realloc(ptr, size);
}

static void main_task(void *arg) {
	(void)arg;
	main_calls++;
}

static void done_task(void *arg) {
	CHECK(wump_chan_send(arg, NULL) == 0);
}

static void spawn_failure(void *arg) {
	enum operation op = *(enum operation *)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	failure = op;
	countdown = 1;
	CHECK(wump_go(done_task, done) == -1);
	CHECK(errno == (op == PROTECT ? EACCES : ENOMEM));
	CHECK(wump_go(done_task, done) == 0);
	CHECK(wump_chan_recv(done, NULL) == 1);
	wump_chan_free(done);
}

static void select_failure(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(0, 0);
	CHECK(ch != NULL);
	wump_case cases[12];
	for (size_t i = 0; i < 12; i++) {
		cases[i] = (wump_case){ ch, WUMP_RECV, NULL, 123 };
	}
	size_t chosen = 456;
	failure = CALLOC;
	countdown = 1;
	CHECK(wump_sel(cases, 12, 0, &chosen) == -1 && errno == ENOMEM);
	CHECK(chosen == 456);
	failure = REALLOC;
	countdown = 1;
	CHECK(wump_sel(cases, 12, 1, &chosen) == -1 && errno == ENOMEM);
	CHECK(chosen == 456);
	for (size_t i = 0; i < 12; i++) {
		CHECK(cases[i].result == 123);
	}
	CHECK(wump_sel(cases, 12, 0, &chosen) == 0 && chosen == SIZE_MAX);
	CHECK(wump_sleep(1) == 0);
	CHECK(wump_chan_close(ch) == 0);
	wump_chan_free(ch);
}

typedef struct timer_arg { wump_chan *ch, *done; } timer_arg;

static void waiting_timer(void *arg) {
	timer_arg *ctx = arg;
	wump_case c = { ctx->ch, WUMP_RECV, NULL, 123 };
	CHECK(wump_sel(&c, 1, INT64_C(3600000000000), NULL) == 1 && c.result == 0);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void timer_growth_failure(void *arg) {
	(void)arg;
	timer_arg ctx = { wump_chan_make(0, 0), wump_chan_make(0, 0) };
	CHECK(ctx.ch != NULL && ctx.done != NULL);
	for (int i = 0; i < 16; i++) {
		CHECK(wump_go(waiting_timer, &ctx) == 0);
	}
	wump_yield();
	failure = REALLOC;
	countdown = 1;
	CHECK(wump_sleep(1) == -1 && errno == ENOMEM);
	CHECK(wump_chan_close(ctx.ch) == 0);
	for (int i = 0; i < 16; i++) {
		CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	}
	wump_chan_free(ctx.ch);
	wump_chan_free(ctx.done);
	CHECK(wump_sleep(1) == 0);
}

int main(void) {
	struct startup_case {
		enum operation op;
		int nth, error;
	} cases[] = {
		{ MUTEX, 1, ENOMEM }, { MUTEX, 2, ENOMEM }, { MUTEX, 4, ENOMEM },
		{ COND, 1, ENOMEM }, { ALIGNED, 1, ENOMEM }, { MAP, 1, ENOMEM },
		{ ATTR, 1, ENOMEM }, { CLOCK, 1, EINVAL },
		{ PROTECT, 1, EACCES }, { THREAD, 1, EAGAIN }, { THREAD, 2, EAGAIN }
	};
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		failure = cases[i].op;
		countdown = cases[i].nth;
		main_calls = 0;
		CHECK(wump_run(main_task, NULL, 4) == -1);
		CHECK(errno == cases[i].error);
		CHECK(main_calls == 0 && mappings == 0 && threads == 0);
		CHECK(wump_run(main_task, NULL, 1) == 0);
		CHECK(main_calls == 1 && mappings == 0 && threads == 0);
	}
	puts("ok - startup failures release mappings and join started workers");
	enum operation ops[] = { MAP, PROTECT };
	for (size_t i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
		CHECK(wump_run(spawn_failure, &ops[i], 1) == 0);
		CHECK(mappings == 0 && threads == 0);
	}
	puts("ok - failed spawn leaves the runtime usable");
	enum operation channel_ops[] = { CALLOC, MALLOC, MUTEX };
	for (size_t i = 0; i < sizeof(channel_ops) / sizeof(channel_ops[0]); i++) {
		failure = channel_ops[i];
		countdown = 1;
		CHECK(wump_chan_make(sizeof(int), 3) == NULL && errno == ENOMEM);
		wump_chan *ch = wump_chan_make(sizeof(int), 3);
		CHECK(ch != NULL);
		wump_chan_free(ch);
	}
	puts("ok - channel allocation and mutex initialization failures");
	CHECK(wump_run(select_failure, NULL, 1) == 0);
	CHECK(mappings == 0 && threads == 0);
	CHECK(wump_run(timer_growth_failure, NULL, 1) == 0);
	CHECK(mappings == 0 && threads == 0);
	puts("ok - selection allocation and parked timer failures leave outputs and existing waits intact");
	return 0;
}
