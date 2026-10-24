#define _POSIX_C_SOURCE 200809L
#include <errno.h>
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

/* Calls below can migrate; never cache libc's native errno pointer. */
extern int wump_test_get_errno(void);

#define CHECK(expr) do { \
	if (!(expr)) { \
		fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, wump_test_get_errno()); \
		abort(); \
	} \
} while (0)
#define MS INT64_C(1000000)

static void api_program(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(sizeof(int), 1);
	CHECK(ch != NULL);
	int value = 99;
	wump_case c = { ch, WUMP_RECV, &value, 123 };
	size_t chosen = 777;
	CHECK(wump_sel(NULL, 1, 0, &chosen) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_sel(&c, 1, -2, &chosen) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_sel(&c, SIZE_MAX, 0, &chosen) == -1 && wump_test_get_errno() == EOVERFLOW);
	CHECK(wump_sel(&c, 1, INT64_MAX, &chosen) == -1 && wump_test_get_errno() == EOVERFLOW);
	CHECK(wump_sleep(-1) == -1 && wump_test_get_errno() == EINVAL);
	c.op = (enum wump_case_op)99;
	CHECK(wump_sel(&c, 1, 0, &chosen) == -1 && wump_test_get_errno() == EINVAL);
	c.op = WUMP_RECV;
	c.data = NULL;
	CHECK(wump_sel(&c, 1, 0, &chosen) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(chosen == 777 && c.result == 123 && value == 99);
	c.data = &value;
	CHECK(wump_sel(&c, 1, 0, &chosen) == 0 && chosen == SIZE_MAX);
	CHECK(c.result == 123 && value == 99);
	CHECK(wump_sel(NULL, 0, 0, NULL) == 0);
	CHECK(wump_sleep(0) == 0);
	c.ch = NULL;
	c.data = NULL;
	CHECK(wump_sel(&c, 1, 1, &chosen) == 0 && chosen == SIZE_MAX);
	CHECK(c.result == 123);
	c.ch = ch;
	c.data = &value;
	CHECK(wump_chan_close(ch) == 0);
	CHECK(wump_sel(&c, 1, -1, &chosen) == 1);
	CHECK(chosen == 0 && c.result == 0 && value == 0);
	c.op = WUMP_SEND;
	CHECK(wump_sel(&c, 1, -1, &chosen) == 1 && wump_test_get_errno() == EPIPE);
	CHECK(chosen == 0 && c.result == -1);
	wump_chan_free(ch);
	ch = wump_chan_make(0, 1);
	CHECK(ch != NULL);
	c = (wump_case){ ch, WUMP_SEND, NULL, 123 };
	CHECK(wump_sel(&c, 1, 0, NULL) == 1 && c.result == 0);
	c.op = WUMP_RECV;
	CHECK(wump_sel(&c, 1, 0, NULL) == 1 && c.result == 1);
	wump_chan_free(ch);
}

static void test_api(void) {
	CHECK(wump_sel(NULL, 0, 0, NULL) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_sleep(1) == -1 && wump_test_get_errno() == EINVAL);
	for (int n = 1; n <= 4; n *= 2) {
		CHECK(wump_run(api_program, NULL, n) == 0);
	}
}

static void ready_program(void *arg) {
	(void)arg;
	wump_chan *ch[3];
	for (int i = 0; i < 3; i++) {
		ch[i] = wump_chan_make(sizeof(int), 1);
		CHECK(ch[i] != NULL);
	}
	int counts[3] = {0};
	for (int repeat = 0; repeat < 6000; repeat++) {
		for (int i = 0; i < 3; i++) {
			int value = 40 + i;
			CHECK(wump_chan_send(ch[i], &value) == 0);
		}
		int out[3] = { -1, -1, -1 };
		wump_case cases[] = {
			{ NULL, WUMP_RECV, NULL, 123 },
			{ ch[2], WUMP_RECV, &out[2], 123 },
			{ ch[0], WUMP_RECV, &out[0], 123 },
			{ NULL, WUMP_SEND, NULL, 123 },
			{ ch[1], WUMP_RECV, &out[1], 123 }
		};
		size_t chosen;
		CHECK(wump_sel(cases, 5, 0, &chosen) == 1);
		CHECK(chosen == 1 || chosen == 2 || chosen == 4);
		for (int i = 0; i < 3; i++) {
			if (cases[chosen].ch == ch[i]) {
				CHECK(out[i] == 40 + i && wump_chan_len(ch[i]) == 0);
				counts[i]++;
			} else {
				int value;
				CHECK(out[i] == -1 && wump_chan_len(ch[i]) == 1);
				CHECK(wump_chan_recv(ch[i], &value) == 1 && value == 40 + i);
			}
		}
		for (size_t i = 0; i < 5; i++) {
			CHECK(cases[i].result == (i == chosen ? 1 : 123));
		}
	}
	for (int i = 0; i < 3; i++) {
		CHECK(counts[i] > 1400 && counts[i] < 2600);
		wump_chan_free(ch[i]);
	}
	wump_chan *same = wump_chan_make(sizeof(int), 1);
	CHECK(same != NULL);
	int source = 42, out = -1;
	wump_case both[] = { { same, WUMP_RECV, &out, 123 }, { same, WUMP_SEND, &source, 123 } };
	for (int i = 0; i < 100; i++) {
		size_t chosen;
		CHECK(wump_sel(both, 2, 0, &chosen) == 1 && chosen == 1);
		CHECK(wump_sel(both, 2, 0, &chosen) == 1 && chosen == 0 && out == 42);
	}
	wump_chan_free(same);
}

static void test_ready(void) {
	CHECK(wump_run(ready_program, NULL, 4) == 0);
}

typedef struct exchange {
	wump_chan *a, *b, *done;
	int sending, index;
} exchange;

static void exchange_worker(void *arg) {
	exchange *ctx = arg;
	int a = ctx->sending ? 101 : -1;
	int b = ctx->sending ? 202 : -1;
	wump_case cases[] = {
		{ ctx->a, ctx->sending ? WUMP_SEND : WUMP_RECV, &a, 123 },
		{ ctx->b, ctx->sending ? WUMP_SEND : WUMP_RECV, &b, 123 },
		{ ctx->b, ctx->sending ? WUMP_SEND : WUMP_RECV, &b, 123 }
	};
	size_t chosen;
	CHECK(wump_sel(cases, 3, -1, &chosen) == 1);
	CHECK(chosen == 1 || chosen == 2);
	CHECK(cases[chosen].result == (ctx->sending ? 0 : 1));
	if (!ctx->sending) {
		CHECK(a == -1 && b == 42);
	}
	CHECK(cases[0].result == 123);
	CHECK(cases[chosen == 1 ? 2 : 1].result == 123);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void parked_program(void *arg) {
	(void)arg;
	exchange ctx = { wump_chan_make(sizeof(int), 0), wump_chan_make(sizeof(int), 0), wump_chan_make(0, 0), 0, 0 };
	CHECK(ctx.a != NULL && ctx.b != NULL && ctx.done != NULL);
	for (int sending = 0; sending <= 1; sending++) {
		ctx.sending = sending;
		CHECK(wump_go(exchange_worker, &ctx) == 0);
		wump_yield();
		int value = 42;
		if (sending) {
			CHECK(wump_chan_recv(ctx.b, &value) == 1 && value == 202);
		} else {
			CHECK(wump_chan_send(ctx.b, &value) == 0);
		}
		CHECK(wump_chan_recv(ctx.done, NULL) == 1);
		wump_case c = { ctx.a, WUMP_SEND, &value, 123 };
		CHECK(wump_sel(&c, 1, 0, NULL) == 0 && c.result == 123);
	}
	wump_chan_free(ctx.a);
	wump_chan_free(ctx.b);
	wump_chan_free(ctx.done);
}

static void test_parked(void) {
	CHECK(wump_run(parked_program, NULL, 1) == 0);
}

static void paired_worker(void *arg) {
	exchange *ctx = arg;
	for (int i = 0; i < 2000; i++) {
		int a = ctx->sending ? i * 2 : -1;
		int b = ctx->sending ? i * 2 + 1 : -1;
		wump_case cases[] = {
			{ ctx->b, ctx->sending ? WUMP_SEND : WUMP_RECV, &b, 123 },
			{ ctx->a, ctx->sending ? WUMP_SEND : WUMP_RECV, &a, 123 }
		};
		if (ctx->sending) {
			wump_case tmp = cases[0];
			cases[0] = cases[1];
			cases[1] = tmp;
		}
		size_t chosen;
		CHECK(wump_sel(cases, 2, -1, &chosen) == 1);
		CHECK(cases[chosen].result == (ctx->sending ? 0 : 1));
		CHECK(cases[1 - chosen].result == 123);
		if (!ctx->sending) {
			CHECK((chosen == 0 && b == i * 2 + 1 && a == -1) ||
				(chosen == 1 && a == i * 2 && b == -1));
		}
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void pair_program(void *arg) {
	(void)arg;
	exchange sender = { wump_chan_make(sizeof(int), 0), wump_chan_make(sizeof(int), 0), wump_chan_make(0, 0), 1, 0 };
	CHECK(sender.a != NULL && sender.b != NULL && sender.done != NULL);
	exchange receiver = sender;
	receiver.sending = 0;
	CHECK(wump_go(paired_worker, &sender) == 0);
	CHECK(wump_go(paired_worker, &receiver) == 0);
	CHECK(wump_chan_recv(sender.done, NULL) == 1);
	CHECK(wump_chan_recv(sender.done, NULL) == 1);
	wump_chan_free(sender.a);
	wump_chan_free(sender.b);
	wump_chan_free(sender.done);
}

static void test_pairs(void) {
	for (int n = 1; n <= 16; n *= 2) {
		CHECK(wump_run(pair_program, NULL, n) == 0);
	}
}

static void self_program(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(sizeof(int), 0);
	CHECK(ch != NULL);
	int sent = 42, received = -1;
	wump_case cases[] = { { ch, WUMP_SEND, &sent, 123 }, { ch, WUMP_RECV, &received, 123 } };
	size_t chosen;
	CHECK(wump_sel(cases, 2, 1000, &chosen) == 0 && chosen == SIZE_MAX);
	CHECK(cases[0].result == 123 && cases[1].result == 123 && received == -1);
	CHECK(wump_chan_close(ch) == 0);
	wump_chan_free(ch);
	CHECK(wump_sleep(MS) == 0);
}

static void test_self(void) {
	CHECK(wump_run(self_program, NULL, 4) == 0);
}

typedef struct busy_arg { atomic_int stop, yields; wump_chan *done; } busy_arg;

static void busy_worker(void *arg) {
	busy_arg *ctx = arg;
	while (!atomic_load(&ctx->stop)) {
		atomic_fetch_add(&ctx->yields, 1);
		wump_yield();
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void sleep_program(void *arg) {
	(void)arg;
	int64_t started = wump_now();
	CHECK(wump_sleep(2 * MS) == 0);
	CHECK(wump_now() - started >= 2 * MS);
	busy_arg ctx;
	atomic_init(&ctx.stop, 0);
	atomic_init(&ctx.yields, 0);
	ctx.done = wump_chan_make(0, 0);
	CHECK(ctx.done != NULL);
	CHECK(wump_go(busy_worker, &ctx) == 0);
	started = wump_now();
	CHECK(wump_sleep(2 * MS) == 0);
	CHECK(wump_now() - started >= 2 * MS);
	atomic_store(&ctx.stop, 1);
	CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	CHECK(atomic_load(&ctx.yields) > 0);
	wump_chan_free(ctx.done);
}

static void test_sleep(void) {
	CHECK(wump_run(sleep_program, NULL, 1) == 0);
	CHECK(wump_run(sleep_program, NULL, 4) == 0);
}

static void expiring_worker(void *arg) {
	exchange *ctx = arg;
	int64_t delay = (int64_t)((ctx->index * 31) % 97 + 1) * 10000;
	int64_t before = wump_now();
	CHECK(wump_sleep(delay) == 0);
	CHECK(wump_now() - before >= delay);
	CHECK(wump_chan_send(ctx->done, &ctx->index) == 0);
}

static void expiring_program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(sizeof(int), 0);
	CHECK(done != NULL);
	exchange args[128];
	for (int i = 0; i < 128; i++) {
		args[i] = (exchange){ .done = done, .index = i };
		CHECK(wump_go(expiring_worker, &args[i]) == 0);
	}
	int seen[128] = {0};
	for (int i = 0; i < 128; i++) {
		int index;
		CHECK(wump_chan_recv(done, &index) == 1 && index >= 0 && index < 128);
		CHECK(seen[index]++ == 0);
	}
	wump_chan_free(done);
}

static void earlier_waiter(void *arg) {
	exchange *ctx = arg;
	wump_case c = { ctx->a, WUMP_RECV, NULL, 123 };
	CHECK(wump_sel(&c, 1, 500 * MS, NULL) == 1 && c.result == 1);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void earlier_program(void *arg) {
	(void)arg;
	exchange ctx = { .a = wump_chan_make(0, 0), .done = wump_chan_make(0, 0) };
	CHECK(ctx.a != NULL && ctx.done != NULL);
	CHECK(wump_go(earlier_waiter, &ctx) == 0);
	wump_yield();
	/* The first timer is already pending. A new, earlier deadline must
	 * wake the idle worker in time to cancel it by communicating. */
	CHECK(wump_sleep(MS) == 0);
	CHECK(wump_chan_send(ctx.a, NULL) == 0);
	CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	wump_chan_free(ctx.a);
	wump_chan_free(ctx.done);
}

static void test_expiry(void) {
	CHECK(wump_run(earlier_program, NULL, 1) == 0);
	CHECK(wump_run(expiring_program, NULL, 1) == 0);
	CHECK(wump_run(expiring_program, NULL, 4) == 0);
}

static void closed_worker(void *arg) {
	exchange *ctx = arg;
	int data[12];
	wump_case cases[12];
	for (size_t i = 0; i < 12; i++) {
		data[i] = 99;
		cases[i] = (wump_case){ i % 2 ? ctx->b : ctx->a,
			ctx->sending ? WUMP_SEND : WUMP_RECV, &data[i], 123 };
	}
	size_t chosen;
	CHECK(wump_sel(cases, 12, INT64_C(3600000000000), &chosen) == 1);
	CHECK(chosen < 12 && chosen % 2 == 1);
	CHECK(cases[chosen].result == (ctx->sending ? -1 : 0));
	if (ctx->sending) {
		CHECK(wump_test_get_errno() == EPIPE);
	}
	for (size_t i = 0; i < 12; i++) {
		CHECK(data[i] == (i == chosen && !ctx->sending ? 0 : 99));
		CHECK(i == chosen || cases[i].result == 123);
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void closed_program(void *arg) {
	(void)arg;
	for (int sending = 0; sending <= 1; sending++) {
		exchange ctx = { wump_chan_make(sizeof(int), 1), wump_chan_make(sizeof(int), 1), wump_chan_make(0, 0), sending, 0 };
		CHECK(ctx.a != NULL && ctx.b != NULL && ctx.done != NULL);
		if (sending) {
			int value = 42;
			CHECK(wump_chan_send(ctx.a, &value) == 0 && wump_chan_send(ctx.b, &value) == 0);
		}
		CHECK(wump_go(closed_worker, &ctx) == 0);
		wump_yield();
		CHECK(wump_chan_close(ctx.b) == 0);
		CHECK(wump_chan_recv(ctx.done, NULL) == 1);
		wump_chan_free(ctx.a);
		wump_chan_free(ctx.b);
		wump_chan_free(ctx.done);
	}
}

static void test_closed(void) {
	CHECK(wump_run(closed_program, NULL, 1) == 0);
}

static void heap_waiter(void *arg) {
	exchange *ctx = arg;
	int64_t delay = 300 * MS + (int64_t)((ctx->index * 7919) % 1000);
	wump_case c = { ctx->a, WUMP_RECV, NULL, 123 };
	int result = wump_sel(&c, 1, delay, NULL);
	CHECK(result == 0 || (result == 1 && c.result == 0));
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void heap_program(void *arg) {
	(void)arg;
	exchange base = { wump_chan_make(0, 0), NULL, wump_chan_make(0, 0), 0, 0 };
	CHECK(base.a != NULL && base.done != NULL);
	exchange args[256];
	for (int i = 0; i < 256; i++) {
		args[i] = base;
		args[i].index = i;
		CHECK(wump_go(heap_waiter, &args[i]) == 0);
	}
	wump_yield();
	CHECK(wump_chan_close(base.a) == 0);
	for (int i = 0; i < 256; i++) {
		CHECK(wump_chan_recv(base.done, NULL) == 1);
	}
	wump_chan_free(base.a);
	wump_chan_free(base.done);
	/* Any orphaned timers now refer to recycled/unmapped task stacks. */
	CHECK(wump_sleep(350 * MS) == 0);
}

static void test_heap(void) {
	CHECK(wump_run(heap_program, NULL, 1) == 0);
	CHECK(wump_run(heap_program, NULL, 4) == 0);
}

static void delayed_send(void *arg) {
	exchange *ctx = arg;
	CHECK(wump_sleep((int64_t)(ctx->index % 4) * 1000) == 0);
	int value = ctx->index;
	wump_case cases[] = { { ctx->a, WUMP_SEND, &value, 123 }, { ctx->b, WUMP_SEND, &value, 123 } };
	int result = wump_sel(cases, 2, 10000, NULL);
	CHECK(result == 0 || result == 1);
	CHECK(wump_chan_send(ctx->done, &result) == 0);
}

static void race_program(void *arg) {
	size_t cap = *(size_t *)arg;
	for (int repeat = 0; repeat < 1000; repeat++) {
		exchange ctx = { wump_chan_make(sizeof(int), cap), wump_chan_make(sizeof(int), cap), wump_chan_make(sizeof(int), 0), 0, repeat };
		CHECK(ctx.a != NULL && ctx.b != NULL && ctx.done != NULL);
		CHECK(wump_go(delayed_send, &ctx) == 0);
		int a = -1, b = -1;
		wump_case cases[] = { { ctx.a, WUMP_RECV, &a, 123 }, { ctx.b, WUMP_RECV, &b, 123 } };
		size_t chosen;
		int result = wump_sel(cases, 2, repeat % 2 ? 1 : 10000, &chosen);
		CHECK(result == 0 || result == 1);
		if (result == 1) {
			CHECK(chosen < 2 && cases[chosen].result == 1);
			CHECK((chosen == 0 && a == repeat && b == -1) || (chosen == 1 && b == repeat && a == -1));
			CHECK(cases[1 - chosen].result == 123);
		} else {
			CHECK(chosen == SIZE_MAX && a == -1 && b == -1);
			CHECK(cases[0].result == 123 && cases[1].result == 123);
		}
		int sent;
		CHECK(wump_chan_recv(ctx.done, &sent) == 1);
		CHECK(!result || sent == 1);
		CHECK(wump_chan_len(ctx.a) + wump_chan_len(ctx.b) == (size_t)(sent - result));
		CHECK(wump_chan_close(ctx.a) == 0 && wump_chan_close(ctx.b) == 0);
		wump_chan_free(ctx.a);
		wump_chan_free(ctx.b);
		wump_chan_free(ctx.done);
	}
	CHECK(wump_sleep(MS) == 0);
}

static void test_races(void) {
	for (int n = 1; n <= 16; n *= 4) {
		for (size_t cap = 0; cap <= 1; cap++) {
			CHECK(wump_run(race_program, &cap, n) == 0);
		}
	}
}

static void abandoned_waiter(void *arg) {
	exchange *ctx = arg;
	wump_case cases[12];
	for (size_t i = 0; i < 12; i++) {
		cases[i] = (wump_case){ i % 2 ? ctx->a : ctx->b, WUMP_RECV, NULL, 123 };
	}
	int result = wump_sel(cases, 12, 3600 * INT64_C(1000000000), NULL);
	CHECK(result == 1 && cases[0].result == 123); /* normally abandoned */
}

static void abandoned_program(void *arg) {
	exchange *ctx = arg;
	for (int i = 0; i < 32; i++) {
		CHECK(wump_go(abandoned_waiter, ctx) == 0);
	}
	wump_yield();
	if (ctx->index) {
		CHECK(wump_chan_close(ctx->a) == 0);
		/* Winners have been readied, but none have resumed on one P. */
	}
}

static void reuse_program(void *arg) {
	exchange *ctx = arg;
	wump_case cases[] = { { ctx->a, WUMP_SEND, NULL, 123 }, { ctx->b, WUMP_SEND, NULL, 123 } };
	CHECK(wump_sel(cases, 2, 0, NULL) == 0);
	CHECK(wump_chan_close(ctx->a) == 0 && wump_chan_close(ctx->b) == 0);
}

static void test_abandoned(void) {
	for (int wake = 0; wake <= 1; wake++) {
		exchange ctx = { wump_chan_make(0, 0), wump_chan_make(0, 0), NULL, 0, wake };
		CHECK(ctx.a != NULL && ctx.b != NULL);
		CHECK(wump_run(abandoned_program, &ctx, 1) == 0);
		if (!wake) {
			CHECK(wump_run(reuse_program, &ctx, 4) == 0);
		}
		wump_chan_free(ctx.a);
		wump_chan_free(ctx.b);
	}
}

static void empty_wait(void *arg) {
	(void)arg;
	CHECK(wump_sel(NULL, 0, -1, NULL) == 1);
}

static void deadlocked_main(void *arg) {
	CHECK(wump_chan_recv(arg, NULL) == 1);
}

static void lone_timer(void *arg) {
	(void)arg;
	CHECK(wump_sleep(MS) == 0);
}

static void deadlock_program(void *arg) {
	CHECK(wump_go(lone_timer, NULL) == 0);
	deadlocked_main(arg);
}

static void test_deadlocks(void) {
	CHECK(wump_run(empty_wait, NULL, 4) == -1 && wump_test_get_errno() == EDEADLK);
	wump_chan *ch = wump_chan_make(0, 0);
	CHECK(ch != NULL);
	CHECK(wump_run(deadlock_program, ch, 4) == -1 && wump_test_get_errno() == EDEADLK);
	wump_chan_free(ch);
}

typedef struct test_case { const char *name; void (*run)(void); } test_case;

int main(int argc, char **argv) {
	struct rlimit core = {0};
	CHECK(setrlimit(RLIMIT_CORE, &core) == 0);
	test_case tests[] = {
		{ "selection API and output contracts", test_api },
		{ "ready cases, duplicate channels, and randomized choice", test_ready },
		{ "parked send/receive and losing waiter cleanup", test_parked },
		{ "selection-to-selection rendezvous and lock ordering", test_pairs },
		{ "selection cannot rendezvous with itself", test_self },
		{ "timers progress while idle and while work remains runnable", test_sleep },
		{ "multiple timer expiry and earlier deadline insertion", test_expiry },
		{ "close wins blocked selections without modifying losing outputs", test_closed },
		{ "timer heap growth and arbitrary cancellation", test_heap },
		{ "channel-timeout races commit one outcome", test_races },
		{ "shutdown detaches pending and readied selections", test_abandoned },
		{ "deadlock after the last timer expires", test_deadlocks }
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
	if (!matched) {
		fprintf(stderr, "no test matched\n");
		return 1;
	}
	return 0;
}
