#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "wump.h"

#define REQUIRE(expr) do { if (!(expr)) { perror(#expr); exit(1); } } while (0)

static int count = 100000;

static double now(void) {
	struct timespec ts;
	REQUIRE(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void report(const char *name, uint64_t operations, double started) {
	double seconds = now() - started;
	printf("wump,%s,%d,%llu,%.6f,%.1f\n", name, wump_nprocs(),
		(unsigned long long)operations, seconds, seconds * 1e9 / (double)operations);
}

static void signal_done(void *arg) {
	REQUIRE(wump_chan_send(arg, NULL) == 0);
}

static void spawn_bench(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	REQUIRE(done != NULL);
	double started = now();
	for (int base = 0; base < count; base += 1024) {
		int batch = count - base < 1024 ? count - base : 1024;
		for (int i = 0; i < batch; i++) {
			REQUIRE(wump_go(signal_done, done) == 0);
		}
		for (int i = 0; i < batch; i++) {
			REQUIRE(wump_chan_recv(done, NULL) == 1);
		}
	}
	report("spawn", (uint64_t)count, started);
	wump_chan_free(done);
}

static void yield_bench(void *arg) {
	(void)arg;
	double started = now();
	for (int i = 0; i < count; i++) {
		wump_yield();
	}
	report("yield", (uint64_t)count, started);
}

typedef struct ping_arg {
	wump_chan *request, *response, *done;
} ping_arg;

static void ping_worker(void *arg) {
	ping_arg *ctx = arg;
	for (int i = 0; i < count; i++) {
		int value;
		REQUIRE(wump_chan_recv(ctx->request, &value) == 1);
		value++;
		REQUIRE(wump_chan_send(ctx->response, &value) == 0);
	}
	REQUIRE(wump_chan_send(ctx->done, NULL) == 0);
}

static void ping_bench(void *arg) {
	(void)arg;
	ping_arg ctx = {
		wump_chan_make(sizeof(int), 0), wump_chan_make(sizeof(int), 0),
		wump_chan_make(0, 0)
	};
	REQUIRE(ctx.request != NULL && ctx.response != NULL && ctx.done != NULL);
	double started = now();
	REQUIRE(wump_go(ping_worker, &ctx) == 0);
	for (int i = 0; i < count; i++) {
		int value;
		REQUIRE(wump_chan_send(ctx.request, &i) == 0);
		REQUIRE(wump_chan_recv(ctx.response, &value) == 1 && value == i + 1);
	}
	REQUIRE(wump_chan_recv(ctx.done, NULL) == 1);
	report("pingpong", (uint64_t)count, started);
	wump_chan_free(ctx.request);
	wump_chan_free(ctx.response);
	wump_chan_free(ctx.done);
}

typedef struct summary { uint64_t count, sum; } summary;
typedef struct mpmc_arg {
	wump_chan *data, *produced, *consumed;
	int index;
} mpmc_arg;

static void produce(void *arg) {
	mpmc_arg *ctx = arg;
	int start = (int)((int64_t)count * ctx->index / 4);
	int end = (int)((int64_t)count * (ctx->index + 1) / 4);
	for (int i = start; i < end; i++) {
		uint64_t value = (uint64_t)i;
		REQUIRE(wump_chan_send(ctx->data, &value) == 0);
	}
	REQUIRE(wump_chan_send(ctx->produced, NULL) == 0);
}

static void consume(void *arg) {
	mpmc_arg *ctx = arg;
	summary result = {0};
	uint64_t value;
	int received;
	while ((received = wump_chan_recv(ctx->data, &value)) == 1) {
		result.count++;
		result.sum += value;
	}
	REQUIRE(received == 0);
	REQUIRE(wump_chan_send(ctx->consumed, &result) == 0);
}

static void mpmc_bench(void *arg) {
	(void)arg;
	mpmc_arg ctx = {
		wump_chan_make(sizeof(uint64_t), 64), wump_chan_make(0, 0),
		wump_chan_make(sizeof(summary), 0), 0
	};
	REQUIRE(ctx.data != NULL && ctx.produced != NULL && ctx.consumed != NULL);
	mpmc_arg args[4];
	double started = now();
	for (int i = 0; i < 4; i++) {
		args[i] = ctx;
		args[i].index = i;
		REQUIRE(wump_go(produce, &args[i]) == 0);
		REQUIRE(wump_go(consume, &ctx) == 0);
	}
	for (int i = 0; i < 4; i++) {
		REQUIRE(wump_chan_recv(ctx.produced, NULL) == 1);
	}
	REQUIRE(wump_chan_close(ctx.data) == 0);
	summary total = {0};
	for (int i = 0; i < 4; i++) {
		summary result;
		REQUIRE(wump_chan_recv(ctx.consumed, &result) == 1);
		total.count += result.count;
		total.sum += result.sum;
	}
	REQUIRE(total.count == (uint64_t)count);
	REQUIRE(total.sum == (uint64_t)count * (uint64_t)(count - 1) / 2);
	report("mpmc", (uint64_t)count, started);
	wump_chan_free(ctx.data);
	wump_chan_free(ctx.produced);
	wump_chan_free(ctx.consumed);
}

typedef struct cpu_arg { wump_chan *done; uint64_t seed; } cpu_arg;

static uint64_t compute(uint64_t x) {
	for (uint64_t i = 0; i < (uint64_t)count * 64; i++) {
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
	}
	return x;
}

static void cpu_worker(void *arg) {
	cpu_arg *ctx = arg;
	uint64_t result = compute(ctx->seed);
	REQUIRE(wump_chan_send(ctx->done, &result) == 0);
}

static void cpu_bench(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(sizeof(uint64_t), 0);
	REQUIRE(done != NULL);
	cpu_arg args[4];
	double started = now();
	for (int i = 0; i < 4; i++) {
		args[i] = (cpu_arg){ done, (uint64_t)i + 1 };
		REQUIRE(wump_go(cpu_worker, &args[i]) == 0);
	}
	uint64_t checksum = 0;
	for (int i = 0; i < 4; i++) {
		uint64_t value;
		REQUIRE(wump_chan_recv(done, &value) == 1);
		checksum ^= value;
	}
	report("cpu", (uint64_t)count * 64 * 4, started);
	REQUIRE(checksum == compute(4)); /* xorshift is linear; 1^2^3^4 == 4 */
	wump_chan_free(done);
}

static void select_bench(void *arg) {
	(void)arg;
	wump_chan *ch[2] = { wump_chan_make(sizeof(int), 1), wump_chan_make(sizeof(int), 1) };
	REQUIRE(ch[0] != NULL && ch[1] != NULL);
	for (int i = 0; i < 2; i++) {
		int value = 42 + i;
		REQUIRE(wump_chan_send(ch[i], &value) == 0);
	}
	double started = now();
	for (int i = 0; i < count; i++) {
		int value;
		wump_case cases[] = { { ch[0], WUMP_RECV, &value, 0 }, { ch[1], WUMP_RECV, &value, 0 } };
		size_t chosen;
		REQUIRE(wump_sel(cases, 2, 0, &chosen) == 1 && chosen < 2);
		REQUIRE(value == 42 + (int)chosen && cases[chosen].result == 1);
		REQUIRE(wump_chan_send(ch[chosen], &value) == 0);
	}
	report("select", (uint64_t)count, started);
	wump_chan_free(ch[0]);
	wump_chan_free(ch[1]);
}

static void sleep_bench(void *arg) {
	(void)arg;
	int iterations = (count + 99) / 100;
	double started = now();
	for (int i = 0; i < iterations; i++) {
		REQUIRE(wump_sleep(1000) == 0);
	}
	report("sleep", (uint64_t)iterations, started);
}

typedef struct echo_arg { wump_io *io; wump_chan *done; int iterations; } echo_arg;

static void io_full(wump_io *io, uint64_t *value, int writing) {
	for (size_t offset = 0; offset < sizeof(*value);) {
		ssize_t n = writing ?
			wump_io_write(io, (char *)value + offset, sizeof(*value) - offset, -1) :
			wump_io_read(io, (char *)value + offset, sizeof(*value) - offset, -1);
		REQUIRE(n > 0);
		offset += (size_t)n;
	}
}

static void echo_worker(void *arg) {
	echo_arg *ctx = arg;
	for (int i = 0; i < ctx->iterations; i++) {
		uint64_t value;
		io_full(ctx->io, &value, 0);
		io_full(ctx->io, &value, 1);
	}
	REQUIRE(wump_chan_send(ctx->done, NULL) == 0);
}

static void echo_bench(void *arg) {
	(void)arg;
	int fd[2];
	REQUIRE(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *client = wump_io_open(fd[0]), *server = wump_io_open(fd[1]);
	wump_chan *done = wump_chan_make(0, 0);
	REQUIRE(client != NULL && server != NULL && done != NULL);
	int iterations = (count + 9) / 10;
	echo_arg ctx = { server, done, iterations };
	double started = now();
	REQUIRE(wump_go(echo_worker, &ctx) == 0);
	for (int i = 0; i < iterations; i++) {
		uint64_t value = (uint64_t)i;
		io_full(client, &value, 1);
		io_full(client, &value, 0);
		REQUIRE(value == (uint64_t)i);
	}
	REQUIRE(wump_chan_recv(done, NULL) == 1);
	report("echo", (uint64_t)iterations, started);
	REQUIRE(wump_io_free(client) == 0 && wump_io_free(server) == 0);
	wump_chan_free(done);
}

static int number(const char *value) {
	char *end;
	errno = 0;
	long n = strtol(value, &end, 10);
	if (errno != 0 || *value == '\0' || *end != '\0' || n <= 0 || n > INT_MAX / 2) {
		fprintf(stderr, "invalid positive integer: %s\n", value);
		exit(1);
	}
	return (int)n;
}

int main(int argc, char **argv) {
	if (argc > 3) {
		fprintf(stderr, "usage: %s [iterations [workers]]\n", argv[0]);
		return 1;
	}
	if (argc > 1) {
		count = number(argv[1]);
	}
	int workers = argc > 2 ? number(argv[2]) : 1;
	wump_fn cases[] = { spawn_bench, yield_bench, ping_bench, mpmc_bench, select_bench, sleep_bench, echo_bench, cpu_bench };
	puts("implementation,workload,workers,operations,seconds,ns_per_op");
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		REQUIRE(wump_run(cases[i], NULL, workers) == 0);
	}
	return 0;
}
