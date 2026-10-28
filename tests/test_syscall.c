#define _GNU_SOURCE
#include <errno.h>
#include <fenv.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "internal.h"

extern int wump_test_get_errno(void);
extern void wump_test_set_errno(int);
#define CHECK(expr) do { if (!(expr)) { \
	fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, wump_test_get_errno()); abort(); \
} } while (0)

static void noop(void *arg) { (void)arg; }
static void count_call(void *arg) { (*(int *)arg)++; }

static void api_program(void *arg) {
	(void)arg;
	CHECK(wump_syscall_exit() == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_blocking(NULL, NULL) == -1 && wump_test_get_errno() == EINVAL);
	int calls = 0;
	pthread_t original = pthread_self();
	wump_test_set_errno(1234);
	CHECK(wump_syscall_enter() == 0);
	CHECK(wump_test_get_errno() == 1234);
	CHECK(pthread_equal(original, pthread_self()));
	CHECK(wump_worker_id() == -1 && wump_nprocs() == 1);
	CHECK(wump_syscall_enter() == -1 && wump_test_get_errno() == EBUSY);
	CHECK(wump_blocking(count_call, &calls) == -1 && wump_test_get_errno() == EBUSY);
	CHECK(calls == 0);
	CHECK(wump_go(noop, NULL) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_sel(NULL, 0, 0, NULL) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_sleep(0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_open(-1) == NULL && wump_test_get_errno() == EINVAL);
	CHECK(wump_run(noop, NULL, 1) == -1 && wump_test_get_errno() == EBUSY);
	wump_yield(); /* No scheduling while this M has no execution slot. */
	wump_test_set_errno(EIO);
	CHECK(wump_syscall_exit() == 0 && wump_test_get_errno() == EIO);
	CHECK(wump_worker_id() == 0 && wump_nprocs() == 1);
	CHECK(wump_blocking(count_call, &calls) == 0 && calls == 1);
}

static void test_api(void) {
	int calls = 0;
	CHECK(wump_syscall_enter() == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_syscall_exit() == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_blocking(count_call, &calls) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(calls == 0);
	CHECK(wump_run(api_program, NULL, 1) == 0);
}

typedef struct pipe_arg {
	int fd[2];
	ssize_t result;
	char byte;
	pthread_t original;
	uintptr_t lo, hi;
	wump_chan *done;
} pipe_arg;

static void native_read(void *arg) {
	pipe_arg *ctx = arg;
	/* ASan may move C locals to a fake stack. Inspect the actual stack
	 * pointer to retain the callback's mapped-stack identity check. */
	uintptr_t sp;
	__asm__ volatile("mov %%rsp, %0" : "=r"(sp));
	CHECK(pthread_equal(ctx->original, pthread_self()));
	CHECK(sp > ctx->lo && sp < ctx->hi);
	CHECK(wump_worker_id() == -1);
	ctx->result = read(ctx->fd[0], &ctx->byte, 1);
}

static void pipe_reader(void *arg) {
	pipe_arg *ctx = arg;
	wump_g *g = wump_self();
	ctx->lo = (uintptr_t)g->stack_lo;
	ctx->hi = (uintptr_t)g;
	ctx->original = pthread_self();
	CHECK(wump_blocking(native_read, ctx) == 0);
	CHECK(ctx->result == 1 && ctx->byte == 'p');
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void pipe_program(void *arg) {
	(void)arg;
	pipe_arg ctx = { .done = wump_chan_make(0, 0) };
	CHECK(ctx.done != NULL && pipe(ctx.fd) == 0);
	CHECK(wump_go(pipe_reader, &ctx) == 0);
	wump_yield();
	/* On one P the native read has blocked the original OS thread.
	 * Its replacement must run this task to release that read. */
	CHECK(write(ctx.fd[1], "p", 1) == 1);
	CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	CHECK(close(ctx.fd[0]) == 0 && close(ctx.fd[1]) == 0);
	wump_chan_free(ctx.done);
}

static void test_pipe(void) {
	CHECK(wump_run(pipe_program, NULL, 1) == 0);
	CHECK(wump_run(pipe_program, NULL, 4) == 0);
}

typedef struct progress_arg { pipe_arg reader; wump_io *writer; } progress_arg;

static void progress_writer(void *arg) {
	progress_arg *ctx = arg;
	CHECK(wump_sleep(INT64_C(1000000)) == 0);
	CHECK(wump_io_write(ctx->writer, "p", 1, INT64_C(1000000000)) == 1);
	CHECK(wump_chan_send(ctx->reader.done, NULL) == 0);
}

static void progress_program(void *arg) {
	(void)arg;
	progress_arg ctx = { .reader.done = wump_chan_make(0, 0) };
	CHECK(ctx.reader.done != NULL && pipe(ctx.reader.fd) == 0);
	ctx.writer = wump_io_open(ctx.reader.fd[1]);
	CHECK(ctx.writer != NULL);
	CHECK(wump_go(pipe_reader, &ctx.reader) == 0);
	CHECK(wump_go(progress_writer, &ctx) == 0);
	CHECK(wump_chan_recv(ctx.reader.done, NULL) == 1);
	CHECK(wump_chan_recv(ctx.reader.done, NULL) == 1);
	CHECK(wump_io_free(ctx.writer) == 0 && close(ctx.reader.fd[0]) == 0);
	wump_chan_free(ctx.reader.done);
}

static void test_progress(void) {
	CHECK(wump_run(progress_program, NULL, 1) == 0);
}

typedef struct native_group {
	pthread_barrier_t barrier;
	atomic_int entered, normal;
	wump_chan *done;
	int nprocs;
} native_group;

static void native_barrier(void *arg) {
	native_group *ctx = arg;
	CHECK(wump_worker_id() == -1);
	atomic_fetch_add(&ctx->entered, 1);
	int result = pthread_barrier_wait(&ctx->barrier);
	CHECK(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD);
	wump_test_set_errno(4321);
	CHECK(wump_checkpoint() == 0 && wump_test_get_errno() == 4321);
}

static void grouped_task(void *arg) {
	native_group *ctx = arg;
	CHECK(wump_blocking(native_barrier, ctx) == 0);
	CHECK(wump_test_get_errno() == 4321);
	CHECK(atomic_load(&ctx->entered) == 32);
	CHECK(atomic_fetch_add(&ctx->normal, 1) < ctx->nprocs);
	/* Hold a normal-code region long enough for illegally resumed
	 * threads to overlap. Every returning task must own a P first. */
	volatile uint64_t x = 1;
	for (int i = 0; i < 100000; i++) {
		x = x * UINT64_C(6364136223846793005) + 1;
	}
	CHECK(x != 0);
	atomic_fetch_sub(&ctx->normal, 1);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void group_program(void *arg) {
	int nprocs = *(int *)arg;
	native_group ctx = { .nprocs = nprocs };
	atomic_init(&ctx.entered, 0);
	atomic_init(&ctx.normal, 0);
	CHECK(pthread_barrier_init(&ctx.barrier, NULL, 32) == 0);
	ctx.done = wump_chan_make(0, 0);
	CHECK(ctx.done != NULL);
	for (int i = 0; i < 32; i++) {
		CHECK(wump_go(grouped_task, &ctx) == 0);
	}
	for (int i = 0; i < 32; i++) {
		CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	}
	CHECK(atomic_load(&ctx.normal) == 0);
	CHECK(pthread_barrier_destroy(&ctx.barrier) == 0);
	wump_chan_free(ctx.done);
}

static void test_limit(void) {
	for (int n = 1; n <= 4; n *= 2) {
		CHECK(wump_run(group_program, &n, n) == 0);
	}
}

typedef struct context_arg { int mode, error; } context_arg;

static void native_context(void *arg) {
	context_arg *ctx = arg;
	CHECK(wump_test_get_errno() == ctx->error);
	CHECK(fegetround() == ctx->mode);
	wump_test_set_errno(ctx->error + 1);
}

static void context_program(void *arg) {
	(void)arg;
	int modes[] = { FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO };
	for (int i = 0; i < 400; i++) {
		context_arg ctx = { modes[i % 4], 1000 + i };
		uint64_t stack[32];
		for (size_t j = 0; j < 32; j++) {
			stack[j] = (uint64_t)i + j;
		}
		CHECK(fesetround(ctx.mode) == 0);
		wump_test_set_errno(ctx.error);
		CHECK(wump_blocking(native_context, &ctx) == 0);
		CHECK(wump_test_get_errno() == ctx.error + 1);
		CHECK(fegetround() == ctx.mode);
		for (size_t j = 0; j < 32; j++) {
			CHECK(stack[j] == (uint64_t)i + j);
		}
		CHECK(wump_worker_id() >= 0 && wump_worker_id() < wump_nprocs());
	}
}

static void test_context(void) {
	CHECK(wump_run(context_program, NULL, 1) == 0);
	CHECK(wump_run(context_program, NULL, 4) == 0);
}

static void no_exit(void *arg) {
	(void)arg;
	CHECK(wump_syscall_enter() == 0);
}

static void test_unbalanced(void) {
	CHECK(wump_run(no_exit, NULL, 1) == -1 && wump_test_get_errno() == EPROTO);
	CHECK(wump_run(noop, NULL, 1) == 0);
}

typedef struct shutdown_arg {
	int fd[2];
	int unbalanced;
	atomic_int entered, main_returned, native_done;
} shutdown_arg;

static void finishing_native(void *arg) {
	shutdown_arg *ctx = arg;
	atomic_store(&ctx->entered, 1);
	char byte;
	CHECK(read(ctx->fd[0], &byte, 1) == 1 && byte == 's');
	atomic_store(&ctx->native_done, 1);
}

static void finishing_task(void *arg) {
	shutdown_arg *ctx = arg;
	if (ctx->unbalanced) {
		CHECK(wump_syscall_enter() == 0);
		finishing_native(ctx);
		/* Detect this protocol error even if main already initiated
		 * successful shutdown while waiting for the native read. */
	} else {
		CHECK(wump_blocking(finishing_native, ctx) == 0);
	}
}

static void shutdown_program(void *arg) {
	shutdown_arg *ctx = arg;
	CHECK(wump_go(finishing_task, ctx) == 0);
	while (!atomic_load(&ctx->entered)) {
		wump_yield();
	}
	atomic_store(&ctx->main_returned, 1);
}

static void *external_release(void *arg) {
	shutdown_arg *ctx = arg;
	while (!atomic_load(&ctx->main_returned)) {
		sched_yield();
	}
	struct timespec delay = { .tv_nsec = 10000000 };
	while (nanosleep(&delay, &delay) != 0) {
		CHECK(wump_test_get_errno() == EINTR);
	}
	CHECK(write(ctx->fd[1], "s", 1) == 1);
	return NULL;
}

static void test_shutdown(void) {
	for (int i = 0; i < 20; i++) {
		shutdown_arg ctx;
		ctx.unbalanced = i % 2;
		atomic_init(&ctx.entered, 0);
		atomic_init(&ctx.main_returned, 0);
		atomic_init(&ctx.native_done, 0);
		CHECK(pipe(ctx.fd) == 0);
		pthread_t thread;
		CHECK(pthread_create(&thread, NULL, external_release, &ctx) == 0);
		int result = wump_run(shutdown_program, &ctx, 1);
		CHECK(ctx.unbalanced ? result == -1 && wump_test_get_errno() == EPROTO : result == 0);
		CHECK(atomic_load(&ctx.native_done) == 1);
		CHECK(pthread_join(thread, NULL) == 0);
		CHECK(close(ctx.fd[0]) == 0 && close(ctx.fd[1]) == 0);
	}
}

static void deadlock_program(void *arg) {
	CHECK(wump_blocking(noop, NULL) == 0);
	CHECK(wump_chan_recv(arg, NULL) == 1);
}

static void test_deadlock(void) {
	wump_chan *ch = wump_chan_make(0, 0);
	CHECK(ch != NULL);
	CHECK(wump_run(deadlock_program, ch, 1) == -1 && wump_test_get_errno() == EDEADLK);
	wump_chan_free(ch);
}

static void *independent_thread(void *arg) {
	(void)arg;
	CHECK(wump_run(context_program, NULL, 2) == 0);
	return NULL;
}

static void test_independent(void) {
	pthread_t threads[4];
	for (int i = 0; i < 4; i++) {
		CHECK(pthread_create(&threads[i], NULL, independent_thread, NULL) == 0);
	}
	for (int i = 0; i < 4; i++) {
		CHECK(pthread_join(threads[i], NULL) == 0);
	}
}

typedef struct test_case { const char *name; void (*run)(void); } test_case;

int main(int argc, char **argv) {
	struct rlimit core = {0};
	CHECK(setrlimit(RLIMIT_CORE, &core) == 0);
	test_case tests[] = {
		{ "marker contexts and blocking API restrictions", test_api },
		{ "one-slot blocking pipe read hands off its queue", test_pipe },
		{ "timers and poller-backed I/O progress on a donated slot", test_progress },
		{ "native overlap and bounded normal execution after exit", test_limit },
		{ "errno, floating point, stack locals, and repeated handoffs", test_context },
		{ "unbalanced marker return reports EPROTO", test_unbalanced },
		{ "shutdown waits for native calls and preserves protocol errors", test_shutdown },
		{ "deadlock detection after native calls finish", test_deadlock },
		{ "independent runtimes keep separate machine caches", test_independent }
	};
	int repeats = 1;
	const char *filter = NULL;
	if (argc == 2 && strcmp(argv[1], "--stress") == 0) {
		repeats = 10;
	} else if (argc == 3 && strcmp(argv[1], "--case") == 0) {
		filter = argv[2];
	} else if (argc != 1) {
		fprintf(stderr, "usage: %s [--stress | --case substring]\n", argv[0]);
		return 1;
	}
	int matched = 0;
	for (int repeat = 0; repeat < repeats; repeat++) {
		for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
			if (filter != NULL && strstr(tests[i].name, filter) == NULL) {
				continue;
			}
			matched++;
			fflush(NULL);
			pid_t pid = fork();
			CHECK(pid >= 0);
			if (pid == 0) {
				unsigned limit = 30;
#ifdef WUMP_VALGRIND
				if (RUNNING_ON_VALGRIND) {
					limit = 120;
				}
#endif
				alarm(limit);
				tests[i].run();
				_exit(0);
			}
			int status;
			CHECK(waitpid(pid, &status, 0) == pid);
			if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
				fprintf(stderr, "FAIL: %s (status=%d, iteration=%d)\n", tests[i].name, status, repeat + 1);
				return 1;
			}
			printf("ok %d - %s\n", repeat + 1, tests[i].name);
		}
	}
	CHECK(matched != 0);
	return 0;
}
