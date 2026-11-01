#define _GNU_SOURCE
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "internal.h"

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static atomic_int mapped, unmapped, live, discarded, fail_discard, cleaned;

void *__real_mmap(void *, size_t, int, int, int, off_t);
void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
	void *map = __real_mmap(addr, len, prot, flags, fd, offset);
	if (map != MAP_FAILED) {
		atomic_fetch_add(&mapped, 1);
		atomic_fetch_add(&live, 1);
	}
	return map;
}

int __real_munmap(void *, size_t);
int __wrap_munmap(void *addr, size_t len) {
	int result = __real_munmap(addr, len);
	if (result == 0) {
		atomic_fetch_add(&unmapped, 1);
		atomic_fetch_sub(&live, 1);
	}
	return result;
}

int __real_madvise(void *, size_t, int);
int __wrap_madvise(void *addr, size_t len, int advice) {
	CHECK(advice == MADV_DONTNEED);
	if (atomic_load(&fail_discard)) {
		errno = EAGAIN;
		return -1;
	}
	int result = __real_madvise(addr, len, advice);
	if (result == 0) {
		unsigned char resident[1024];
		size_t pages = len / (size_t)sysconf(_SC_PAGESIZE);
		CHECK(pages > 0 && pages <= sizeof(resident));
		CHECK(mincore(addr, len, resident) == 0);
		for (size_t i = 0; i < pages; i++) CHECK(!(resident[i] & 1));
		atomic_fetch_add(&discarded, 1);
	}
	return result;
}

typedef struct context { wump_chan *done; wump_g *task; } context;

static void enter(void *arg) { (void)arg; }

static void cleanup(void *arg) {
	context *ctx = arg;
	CHECK(wump_self() == NULL);
	/* The guard-adjacent canary must not be discarded before cleanup. */
	CHECK(*ctx->task->stack_lo == WUMP_STACK_CANARY);
	atomic_fetch_add(&cleaned, 1);
}

static __attribute__((noinline)) void child(void *arg) {
	context *ctx = arg;
	volatile unsigned char bytes[65536];
	for (int i = 0; i < 65536; i += 4096) bytes[i] = 0x5a;
	ctx->task = wump_self();
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
	for (int i = 0; i < 65536; i += 4096) CHECK(bytes[i] == 0x5a);
}

static void batch(int count) {
	wump_chan *done = wump_chan_make(0, 0);
	context *contexts = calloc((size_t)count, sizeof(*contexts));
	CHECK(done != NULL && contexts != NULL);
	int before = atomic_load(&cleaned);
	for (int i = 0; i < count; i++) {
		contexts[i].done = done;
		CHECK(wump_go_context(child, &contexts[i], enter, cleanup) == 0);
	}
	for (int i = 0; i < count; i++) CHECK(wump_chan_recv(done, NULL) == 1);
	while (atomic_load(&cleaned) != before + count) wump_yield();
	wump_chan_free(done);
	free(contexts);
}

static void native_noop(void *arg) { (void)arg; }

static void reuse(void *arg) {
	(void)arg;
	batch(256);
	CHECK(atomic_load(&discarded) > 0);
	int before = atomic_load(&mapped);
	batch(256);
	CHECK(atomic_load(&mapped) == before);
	CHECK(wump_blocking(native_noop, NULL) == 0);
	batch(256);
	CHECK(atomic_load(&mapped) == before);
	/* Retained mappings must stay bounded even after a larger population. */
	batch(2048);
	CHECK(atomic_load(&live) <= 1 + 32 + 1024);
	CHECK(atomic_load(&unmapped) > 0);
}

static void discard_failure(void *arg) {
	(void)arg;
	atomic_store(&fail_discard, 1);
	batch(256);
	CHECK(atomic_load(&live) <= 1 + 32);
	atomic_store(&fail_discard, 0);
	batch(256);
	int before = atomic_load(&mapped);
	batch(256);
	CHECK(atomic_load(&mapped) == before);
}

static void parallel(void *arg) { (void)arg; for (int i = 0; i < 4; i++) batch(512); }

int main(void) {
	CHECK(wump_run(reuse, NULL, 1) == 0);
	CHECK(atomic_load(&live) == 0);
	CHECK(wump_run(discard_failure, NULL, 1) == 0);
	CHECK(atomic_load(&live) == 0);
	CHECK(wump_run(parallel, NULL, 4) == 0);
	CHECK(atomic_load(&live) == 0);
	puts("ok - bounded stack reuse releases cold pages after cleanup, survives native handoff and discard failure, and unmaps all stacks at shutdown");
	return 0;
}
