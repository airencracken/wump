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

enum operation { NONE, MUTEX, COND, ALIGNED, MAP, PROTECT, THREAD, MALLOC, CALLOC };
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

int main(void) {
	struct startup_case {
		enum operation op;
		int nth, error;
	} cases[] = {
		{ MUTEX, 1, ENOMEM }, { MUTEX, 2, ENOMEM }, { MUTEX, 4, ENOMEM },
		{ COND, 1, ENOMEM }, { ALIGNED, 1, ENOMEM }, { MAP, 1, ENOMEM },
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
	return 0;
}
