#define _GNU_SOURCE
#include <errno.h>
#include <fenv.h>
#include <pthread.h>
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

#define CHECK(expr) do { \
	if (!(expr)) { \
		fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, errno); \
		abort(); \
	} \
} while (0)

extern int wump_test_registers(void);
extern void wump_test_set_errno(int);
extern int wump_test_get_errno(void);

static void noop(void *arg) {
	(void)arg;
}

static void api_program(void *arg) {
	int expected = *(int *)arg;
	CHECK(wump_nprocs() == expected);
	CHECK(wump_worker_id() >= 0 && wump_worker_id() < expected);
	CHECK(wump_run(noop, NULL, 1) == -1 && errno == EBUSY);
	CHECK(wump_go(NULL, NULL) == -1 && errno == EINVAL);
	CHECK(wump_chan_send(NULL, NULL) == -1 && errno == EINVAL);
	CHECK(wump_chan_recv(NULL, NULL) == -1 && errno == EINVAL);
	CHECK(wump_chan_close(NULL) == -1 && errno == EINVAL);
	wump_chan *ch = wump_chan_make(sizeof(int), 1);
	CHECK(ch != NULL);
	CHECK(wump_chan_send(ch, NULL) == -1 && errno == EINVAL);
	CHECK(wump_chan_recv(ch, NULL) == -1 && errno == EINVAL);
	CHECK(wump_chan_close(ch) == 0);
	int value = 99;
	CHECK(wump_chan_recv(ch, &value) == 0 && value == 0);
	CHECK(wump_chan_send(ch, &value) == -1 && errno == EPIPE);
	CHECK(wump_chan_close(ch) == -1 && errno == EPIPE);
	wump_chan_free(ch);
}

static void test_api(void) {
	CHECK(wump_nprocs() == 0 && wump_worker_id() == -1);
	CHECK(wump_run(NULL, NULL, 1) == -1 && errno == EINVAL);
	CHECK(wump_run(noop, NULL, -1) == -1 && errno == EINVAL);
	CHECK(wump_go(noop, NULL) == -1 && errno == EINVAL);
	wump_yield();
	CHECK(wump_chan_make(2, SIZE_MAX) == NULL && errno == EOVERFLOW);
	CHECK(wump_chan_len(NULL) == 0 && wump_chan_cap(NULL) == 0);
	wump_chan_free(NULL);
	wump_chan *ch = wump_chan_make(sizeof(int), 1);
	CHECK(ch != NULL);
	int value = 1;
	CHECK(wump_chan_send(ch, &value) == -1 && errno == EINVAL);
	CHECK(wump_chan_recv(ch, &value) == -1 && errno == EINVAL);
	CHECK(wump_chan_close(ch) == -1 && errno == EINVAL);
	wump_chan_free(ch);
	for (int n = 1; n <= 4; n *= 2) {
		CHECK(wump_run(api_program, &n, n) == 0);
	}
	int cpus = (int)sysconf(_SC_NPROCESSORS_ONLN);
	CHECK(wump_run(api_program, &cpus, 0) == 0);
}

static void test_guard(void) {
	CHECK(wump_stack_new(SIZE_MAX) == NULL && errno == EINVAL);
	CHECK(wump_stack_new(1) == NULL && errno == EINVAL);
	wump_g *g = wump_stack_new(WUMP_STACK_SIZE);
	CHECK(g != NULL && *g->stack_lo == WUMP_STACK_CANARY);
	CHECK((uintptr_t)g % 16 == 0);
	pid_t pid = fork();
	CHECK(pid >= 0);
	if (pid == 0) {
		/* Sanitizers install a SIGSEGV handler. This child intentionally
		 * faults and must expose the kernel signal to its parent. */
		CHECK(signal(SIGSEGV, SIG_DFL) != SIG_ERR);
#ifdef WUMP_VALGRIND
		/* Only this intentional fault is excluded from error reporting;
		 * its parent must still observe the real guard-page SIGSEGV. */
		VALGRIND_DISABLE_ERROR_REPORTING;
#endif
		*(volatile char *)g->map = 1;
		_exit(0);
	}
	int status;
	CHECK(waitpid(pid, &status, 0) == pid);
	CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
	wump_stack_free(g);
}

typedef struct context_arg {
	wump_chan *done;
	int mode, error;
} context_arg;

static void context_worker(void *arg) {
	context_arg *ctx = arg;
	CHECK(fesetround(ctx->mode) == 0);
	wump_test_set_errno(ctx->error);
	CHECK(wump_test_registers() == 0);
	for (int i = 0; i < 1000; i++) {
		CHECK(fegetround() == ctx->mode);
		CHECK(wump_test_get_errno() == ctx->error);
		wump_yield();
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void context_program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	int modes[] = { FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO };
	context_arg args[16];
	for (int i = 0; i < 16; i++) {
		args[i] = (context_arg){ done, modes[i % 4], 100 + i };
		CHECK(wump_go(context_worker, &args[i]) == 0);
	}
	for (int i = 0; i < 16; i++) {
		CHECK(wump_chan_recv(done, NULL) == 1);
	}
	wump_chan_free(done);
}

static void test_context(void) {
	for (int n = 1; n <= 4; n *= 2) {
		CHECK(wump_run(context_program, NULL, n) == 0);
	}
}

static void signal_done(void *arg) {
	wump_chan *done = arg;
	CHECK(wump_chan_send(done, NULL) == 0);
}

static void spawn_program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 31);
	CHECK(done != NULL);
	for (int i = 0; i < 4096; i++) {
		CHECK(wump_go(signal_done, done) == 0);
	}
	for (int i = 0; i < 4096; i++) {
		CHECK(wump_chan_recv(done, NULL) == 1);
	}
	/* Sequential spawn/receive exercises cached-stack reinitialization. */
	for (int i = 0; i < 1000; i++) {
		CHECK(wump_go(signal_done, done) == 0);
		CHECK(wump_chan_recv(done, NULL) == 1);
	}
	wump_chan_free(done);
}

static void test_spawn(void) {
	CHECK(wump_run(spawn_program, NULL, 1) == 0);
	CHECK(wump_run(spawn_program, NULL, 4) == 0);
}

typedef struct parallel_arg {
	atomic_int started;
	atomic_uint workers;
	wump_chan *done;
} parallel_arg;

static void parallel_worker(void *arg) {
	parallel_arg *ctx = arg;
	atomic_fetch_or(&ctx->workers, 1u << wump_worker_id());
	atomic_fetch_add(&ctx->started, 1);
	/* Deliberately no yield: four tasks must really execute on four
	 * OS threads to pass this barrier. The harness bounds deadlocks. */
	while (atomic_load(&ctx->started) != 4) {
		__asm__ volatile("pause");
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void parallel_program(void *arg) {
	(void)arg;
	parallel_arg ctx = { .started = ATOMIC_VAR_INIT(0), .workers = ATOMIC_VAR_INIT(0) };
	ctx.done = wump_chan_make(0, 0);
	CHECK(ctx.done != NULL);
	for (int i = 0; i < 4; i++) {
		CHECK(wump_go(parallel_worker, &ctx) == 0);
	}
	for (int i = 0; i < 4; i++) {
		CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	}
	CHECK(atomic_load(&ctx.workers) == 15u);
	wump_chan_free(ctx.done);
}

static void test_parallel(void) {
	CHECK(wump_run(parallel_program, NULL, 4) == 0);
}

typedef struct checkpoint_arg {
	atomic_uint started;
	wump_chan *done;
} checkpoint_arg;

static void checkpoint_worker(void *arg) {
	checkpoint_arg *ctx = arg;
	unsigned id = atomic_fetch_add(&ctx->started, 1);
	wump_test_set_errno(100 + (int)id);
	while (atomic_load(&ctx->started) != 16) {
		wump_checkpoint();
		CHECK(wump_test_get_errno() == 100 + (int)id);
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void checkpoint_program(void *arg) {
	(void)arg;
	checkpoint_arg ctx = { .started = ATOMIC_VAR_INIT(0), .done = wump_chan_make(0, 0) };
	CHECK(ctx.done != NULL);
	CHECK(wump_checkpoint() == 0); /* A fresh dispatch has its full budget. */
	for (int i = 0; i < 16; i++) {
		CHECK(wump_go(checkpoint_worker, &ctx) == 0);
	}
	wump_test_set_errno(999);
	while (atomic_load(&ctx.started) != 16) {
		int result = wump_checkpoint();
		CHECK(result == 0 || result == 1);
		CHECK(wump_test_get_errno() == 999);
	}
	for (int i = 0; i < 16; i++) CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	wump_chan_free(ctx.done);
}

static void checkpoint_stop(void *arg) {
	(void)arg;
	wump_halt(ECANCELED);
	/* Shutdown must suspend even before the first time budget is started. */
	wump_checkpoint();
	abort();
}

static void test_checkpoint(void) {
	wump_test_set_errno(123);
	CHECK(wump_checkpoint() == 0 && wump_test_get_errno() == 123);
	for (int n = 1; n <= 4; n *= 2) {
		CHECK(wump_run(checkpoint_program, NULL, n) == 0);
	}
	CHECK(wump_run(checkpoint_stop, NULL, 1) == -1 && errno == ECANCELED);
}

typedef struct timer_fairness_arg {
	atomic_uint switches;
	atomic_int stop;
	wump_chan *done;
} timer_fairness_arg;

static void timer_fairness_worker(void *arg) {
	timer_fairness_arg *ctx = arg;
	while (!atomic_load(&ctx->stop)) {
		if (wump_checkpoint()) atomic_fetch_add(&ctx->switches, 1);
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void timer_fairness_program(void *arg) {
	(void)arg;
	timer_fairness_arg ctx = { .switches = ATOMIC_VAR_INIT(0), .stop = ATOMIC_VAR_INIT(0),
		.done = wump_chan_make(0, 0) };
	CHECK(ctx.done != NULL);
	CHECK(wump_go(timer_fairness_worker, &ctx) == 0);
	CHECK(wump_sleep(INT64_C(1000000)) == 0);
	/* Count dispatches instead of imposing a tight host latency threshold.
	 * The old 61-dispatch polling rule kept an expired timer behind 60
	 * complete CPU quanta, even with just one runnable competitor. */
	CHECK(atomic_load(&ctx.switches) < 8);
	atomic_store(&ctx.stop, 1);
	CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	wump_chan_free(ctx.done);
}

static void test_timer_fairness(void) {
	CHECK(wump_run(timer_fairness_program, NULL, 1) == 0);
}

typedef struct fifo_arg {
	wump_chan *ch, *done;
	int value;
} fifo_arg;

static void fifo_sender(void *arg) {
	fifo_arg *ctx = arg;
	CHECK(wump_chan_send(ctx->ch, &ctx->value) == 0);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void fifo_receiver(void *arg) {
	fifo_arg *ctx = arg;
	int value;
	CHECK(wump_chan_recv(ctx->ch, &value) == 1);
	CHECK(value == ctx->value);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void fifo_program(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(sizeof(int), 3);
	wump_chan *done = wump_chan_make(0, 32);
	CHECK(ch != NULL && done != NULL);
	CHECK(wump_chan_cap(ch) == 3 && wump_chan_len(ch) == 0);
	for (int i = 1; i <= 3; i++) {
		CHECK(wump_chan_send(ch, &i) == 0);
	}
	fifo_arg fourth = { ch, done, 4 };
	CHECK(wump_go(fifo_sender, &fourth) == 0);
	wump_yield();
	CHECK(wump_chan_len(ch) == 3 && wump_chan_len(done) == 0);
	for (int i = 1; i <= 4; i++) {
		int value;
		CHECK(wump_chan_recv(ch, &value) == 1 && value == i);
		CHECK(wump_chan_len(ch) == (i == 1 ? 3u : (size_t)(4 - i)));
	}
	CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(wump_chan_close(ch) == 0);
	int value = -1;
	CHECK(wump_chan_recv(ch, &value) == 0 && value == 0);
	wump_chan_free(ch);
	ch = wump_chan_make(sizeof(int), 0);
	CHECK(ch != NULL);
	fifo_arg args[32];
	for (int i = 0; i < 32; i++) {
		args[i] = (fifo_arg){ ch, done, i };
		CHECK(wump_go(fifo_sender, &args[i]) == 0);
	}
	wump_yield();
	for (int i = 0; i < 32; i++) {
		CHECK(wump_chan_recv(ch, &value) == 1 && value == i);
	}
	for (int i = 0; i < 32; i++) {
		CHECK(wump_chan_recv(done, NULL) == 1);
	}
	for (int i = 0; i < 32; i++) {
		CHECK(wump_go(fifo_receiver, &args[i]) == 0);
	}
	wump_yield();
	for (int i = 0; i < 32; i++) {
		CHECK(wump_chan_send(ch, &i) == 0);
	}
	for (int i = 0; i < 32; i++) {
		CHECK(wump_chan_recv(done, NULL) == 1);
	}
	wump_chan_free(ch);
	wump_chan_free(done);
}

static void test_fifo(void) {
	CHECK(wump_run(fifo_program, NULL, 1) == 0);
}

static void model_program(void *arg) {
	(void)arg;
	size_t caps[] = { 1, 2, 3, 7, 17 };
	uint32_t random = 0x12345678;
	for (size_t c = 0; c < sizeof(caps) / sizeof(caps[0]); c++) {
		wump_chan *ch = wump_chan_make(sizeof(uint32_t), caps[c]);
		CHECK(ch != NULL);
		uint32_t model[17];
		size_t len = 0;
		for (int i = 0; i < 20000; i++) {
			random ^= random << 13;
			random ^= random >> 17;
			random ^= random << 5;
			if (len == 0 || (len < caps[c] && (random & 1))) {
				uint32_t value = random;
				CHECK(wump_chan_send(ch, &value) == 0);
				model[len++] = value;
				value = 0; /* Mutation of the source cannot alter the copy. */
			} else {
				uint32_t value;
				CHECK(wump_chan_recv(ch, &value) == 1 && value == model[0]);
				len--;
				memmove(model, model + 1, len * sizeof(*model));
			}
			CHECK(wump_chan_len(ch) == len && wump_chan_cap(ch) == caps[c]);
		}
		CHECK(wump_chan_close(ch) == 0);
		for (size_t i = 0; i < len; i++) {
			uint32_t value;
			CHECK(wump_chan_recv(ch, &value) == 1 && value == model[i]);
		}
		uint32_t value = UINT32_MAX;
		CHECK(wump_chan_recv(ch, &value) == 0 && value == 0);
		wump_chan_free(ch);
	}
}

static void test_model(void) {
	CHECK(wump_run(model_program, NULL, 4) == 0);
}

static void close_waiter(void *arg) {
	fifo_arg *ctx = arg;
	int value = 12345;
	if (ctx->value) {
		CHECK(wump_chan_send(ctx->ch, &value) == -1 && errno == EPIPE);
	} else {
		CHECK(wump_chan_recv(ctx->ch, &value) == 0 && value == 0);
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void close_program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	for (int sending = 0; sending <= 1; sending++) {
		for (size_t cap = 0; cap <= 3; cap += 3) {
			wump_chan *ch = wump_chan_make(sizeof(int), cap);
			CHECK(ch != NULL);
			for (size_t i = 0; sending && i < cap; i++) {
				int value = (int)i;
				CHECK(wump_chan_send(ch, &value) == 0);
			}
			fifo_arg ctx = { ch, done, sending };
			for (int i = 0; i < 32; i++) {
				CHECK(wump_go(close_waiter, &ctx) == 0);
			}
			wump_yield();
			CHECK(wump_chan_close(ch) == 0);
			for (size_t i = 0; sending && i < cap; i++) {
				int value = -1;
				CHECK(wump_chan_recv(ch, &value) == 1 && value == (int)i);
			}
			wump_chan_free(ch); /* Woken tasks have not resumed yet. */
			for (int i = 0; i < 32; i++) {
				CHECK(wump_chan_recv(done, NULL) == 1);
			}
		}
	}
	wump_chan_free(done);
}

static void test_close(void) {
	CHECK(wump_run(close_program, NULL, 1) == 0);
}

static void parallel_close_program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	for (int repeat = 0; repeat < 100; repeat++) {
		for (int sending = 0; sending <= 1; sending++) {
			wump_chan *ch = wump_chan_make(sizeof(int), 1);
			CHECK(ch != NULL);
			if (sending) {
				int value = 42;
				CHECK(wump_chan_send(ch, &value) == 0);
			}
			fifo_arg ctx = { ch, done, sending };
			for (int i = 0; i < 16; i++) {
				CHECK(wump_go(close_waiter, &ctx) == 0);
			}
			/* Some operations may already be parked; others may enter
			 * after close. All must observe the closed state. */
			CHECK(wump_chan_close(ch) == 0);
			for (int i = 0; i < 16; i++) {
				CHECK(wump_chan_recv(done, NULL) == 1);
			}
			if (sending) {
				int value;
				CHECK(wump_chan_recv(ch, &value) == 1 && value == 42);
			}
			wump_chan_free(ch);
		}
	}
	wump_chan_free(done);
}

static void test_parallel_close(void) {
	CHECK(wump_run(parallel_close_program, NULL, 4) == 0);
}

static void lifetime_sender(void *arg) {
	int value = 42;
	CHECK(wump_chan_send(arg, &value) == 0);
}

static void lifetime_program(void *arg) {
	(void)arg;
	for (int i = 0; i < 4000; i++) {
		wump_chan *ch = wump_chan_make(sizeof(int), 0);
		CHECK(ch != NULL);
		CHECK(wump_go(lifetime_sender, ch) == 0);
		int value;
		CHECK(wump_chan_recv(ch, &value) == 1 && value == 42);
		/* Regression: rendezvous publishes the receiver while the sender
		 * is still in its critical section. Free must wait for it. */
		wump_chan_free(ch);
	}
}

static void test_lifetime(void) {
	CHECK(wump_run(lifetime_program, NULL, 4) == 0);
}

typedef struct message {
	uint64_t id, check;
	unsigned char bytes[129];
} message;

typedef struct mpmc_arg {
	wump_chan *data, *produced, *consumed;
	atomic_int *seen;
	int per_producer, total;
} mpmc_arg;

typedef struct producer_arg {
	mpmc_arg *ctx;
	int index;
} producer_arg;

static void producer(void *arg) {
	producer_arg *p = arg;
	mpmc_arg *ctx = p->ctx;
	for (int i = 0; i < ctx->per_producer; i++) {
		message msg;
		memset(&msg, 0, sizeof(msg));
		msg.id = (uint64_t)(p->index * ctx->per_producer + i);
		msg.check = msg.id ^ UINT64_C(0xabcddcba12345678);
		memset(msg.bytes, (unsigned char)msg.id, sizeof(msg.bytes));
		CHECK(wump_chan_send(ctx->data, &msg) == 0);
		if ((msg.id * 17 + 3) % 31 == 0) {
			wump_yield();
		}
	}
	CHECK(wump_chan_send(ctx->produced, NULL) == 0);
}

static void consumer(void *arg) {
	mpmc_arg *ctx = arg;
	message msg;
	int result;
	while ((result = wump_chan_recv(ctx->data, &msg)) == 1) {
		CHECK(msg.id < (uint64_t)ctx->total);
		CHECK(msg.check == (msg.id ^ UINT64_C(0xabcddcba12345678)));
		for (size_t i = 0; i < sizeof(msg.bytes); i++) {
			CHECK(msg.bytes[i] == (unsigned char)msg.id);
		}
		CHECK(atomic_fetch_add(&ctx->seen[msg.id], 1) == 0);
		if ((msg.id * 7 + 11) % 37 == 0) {
			wump_yield();
		}
	}
	CHECK(result == 0);
	message zero = {0};
	CHECK(memcmp(&msg, &zero, sizeof(msg)) == 0);
	CHECK(wump_chan_send(ctx->consumed, NULL) == 0);
}

static void mpmc_program(void *arg) {
	size_t cap = *(size_t *)arg;
	mpmc_arg ctx = { .per_producer = 1000, .total = 8000 };
	ctx.data = wump_chan_make(sizeof(message), cap);
	ctx.produced = wump_chan_make(0, 0);
	ctx.consumed = wump_chan_make(0, 0);
	ctx.seen = calloc((size_t)ctx.total, sizeof(*ctx.seen));
	CHECK(ctx.data != NULL && ctx.produced != NULL && ctx.consumed != NULL && ctx.seen != NULL);
	for (int i = 0; i < ctx.total; i++) {
		atomic_init(&ctx.seen[i], 0);
	}
	producer_arg args[8];
	for (int i = 0; i < 8; i++) {
		args[i] = (producer_arg){ &ctx, i };
		CHECK(wump_go(producer, &args[i]) == 0);
		CHECK(wump_go(consumer, &ctx) == 0);
	}
	for (int i = 0; i < 8; i++) {
		CHECK(wump_chan_recv(ctx.produced, NULL) == 1);
	}
	CHECK(wump_chan_close(ctx.data) == 0);
	for (int i = 0; i < 8; i++) {
		CHECK(wump_chan_recv(ctx.consumed, NULL) == 1);
	}
	for (int i = 0; i < ctx.total; i++) {
		CHECK(atomic_load(&ctx.seen[i]) == 1);
	}
	free(ctx.seen);
	wump_chan_free(ctx.data);
	wump_chan_free(ctx.produced);
	wump_chan_free(ctx.consumed);
}

static void test_mpmc(void) {
	size_t caps[] = { 0, 1, 7, 256 };
	for (int n = 1; n <= 16; n *= 2) {
		for (size_t i = 0; i < sizeof(caps) / sizeof(caps[0]); i++) {
			CHECK(wump_run(mpmc_program, &caps[i], n) == 0);
		}
	}
}

static void zero_program(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(0, SIZE_MAX);
	CHECK(ch != NULL);
	for (int i = 0; i < 100; i++) {
		CHECK(wump_chan_send(ch, NULL) == 0);
	}
	CHECK(wump_chan_len(ch) == 100);
	CHECK(wump_chan_close(ch) == 0);
	for (int i = 0; i < 100; i++) {
		CHECK(wump_chan_recv(ch, NULL) == 1);
	}
	CHECK(wump_chan_recv(ch, NULL) == 0);
	wump_chan_free(ch);
}

static void test_zero(void) {
	CHECK(wump_run(zero_program, NULL, 1) == 0);
}

typedef struct abandon_arg {
	wump_chan *senders, *receivers;
} abandon_arg;

static void blocked_send(void *arg) {
	CHECK(wump_chan_send(arg, NULL) == 0);
}

static void blocked_recv(void *arg) {
	CHECK(wump_chan_recv(arg, NULL) == 1);
}

static void abandon_program(void *arg) {
	abandon_arg *ctx = arg;
	for (int i = 0; i < 32; i++) {
		CHECK(wump_go(blocked_send, ctx->senders) == 0);
		CHECK(wump_go(blocked_recv, ctx->receivers) == 0);
	}
	wump_yield();
}

static void reuse_program(void *arg) {
	abandon_arg *ctx = arg;
	CHECK(wump_go(blocked_send, ctx->receivers) == 0);
	CHECK(wump_chan_recv(ctx->receivers, NULL) == 1);
	CHECK(wump_go(blocked_recv, ctx->senders) == 0);
	CHECK(wump_chan_send(ctx->senders, NULL) == 0);
}

static void test_abandon(void) {
	abandon_arg ctx = { wump_chan_make(0, 0), wump_chan_make(0, 0) };
	CHECK(ctx.senders != NULL && ctx.receivers != NULL);
	for (int i = 0; i < 20; i++) {
		CHECK(wump_run(abandon_program, &ctx, 1) == 0);
		CHECK(wump_run(reuse_program, &ctx, 2) == 0);
	}
	wump_chan_free(ctx.senders);
	wump_chan_free(ctx.receivers);
}

static void test_deadlock(void) {
	wump_chan *ch = wump_chan_make(0, 0);
	CHECK(ch != NULL);
	for (int n = 1; n <= 4; n *= 2) {
		CHECK(wump_run(blocked_recv, ch, n) == -1 && errno == EDEADLK);
		CHECK(wump_run(blocked_send, ch, n) == -1 && errno == EDEADLK);
	}
	wump_chan_free(ch);
	CHECK(wump_run(noop, NULL, 2) == 0);
}

static void *independent_thread(void *arg) {
	(void)arg;
	for (int i = 0; i < 5; i++) {
		size_t cap = (size_t)i;
		CHECK(wump_run(mpmc_program, &cap, 2) == 0);
	}
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

typedef struct test_case {
	const char *name;
	void (*run)(void);
} test_case;

int main(int argc, char **argv) {
	struct rlimit core = { 0, 0 };
	CHECK(setrlimit(RLIMIT_CORE, &core) == 0);
	test_case tests[] = {
		{ "API validation and repeated startup", test_api },
		{ "guard page and stack boundaries", test_guard },
		{ "registers, floating point, and errno", test_context },
		{ "spawn, queue overflow, and stack reuse", test_spawn },
		{ "four workers execute in parallel", test_parallel },
		{ "compute checkpoints provide fairness, preserve errno, and stop", test_checkpoint },
		{ "expired timers compete with compute quanta promptly", test_timer_fairness },
		{ "buffer and waiter FIFO ordering", test_fifo },
		{ "randomized buffer operations match a FIFO model", test_model },
		{ "close wakes blocked senders and receivers", test_close },
		{ "close races with entering operations", test_parallel_close },
		{ "channel free waits for rendezvous publication", test_lifetime },
		{ "MPMC integrity across capacities and worker counts", test_mpmc },
		{ "zero-sized values", test_zero },
		{ "main exit unlinks abandoned waiters", test_abandon },
		{ "deadlock detection and recovery", test_deadlock },
		{ "independent concurrent runtimes", test_independent }
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
				unsigned deadline = 30;
#ifdef WUMP_VALGRIND
				if (RUNNING_ON_VALGRIND) {
					deadline = 120;
				}
#endif
				alarm(deadline);
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
	if (matched == 0) {
		fprintf(stderr, "no test matched: %s\n", filter);
		return 1;
	}
	return 0;
}
