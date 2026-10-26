#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "wump.h"

#define CHECK(expr) do { if (!(expr)) { perror(#expr); exit(1); } } while (0)

typedef struct pipe_arg { int fd[2]; ssize_t result; char byte; wump_chan *done; } pipe_arg;

static void native_read(void *arg) {
	pipe_arg *ctx = arg;
	do {
		ctx->result = read(ctx->fd[0], &ctx->byte, 1);
	} while (ctx->result < 0 && errno == EINTR);
}

static void writer(void *arg) {
	pipe_arg *ctx = arg;
	CHECK(wump_sleep(INT64_C(10000000)) == 0);
	CHECK(write(ctx->fd[1], "b", 1) == 1);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void program(void *arg) {
	(void)arg;
	pipe_arg ctx = { .done = wump_chan_make(0, 0) };
	CHECK(ctx.done != NULL && pipe(ctx.fd) == 0);
	CHECK(wump_go(writer, &ctx) == 0);
	/* The callback's read blocks this OS thread. A replacement runs the
	 * writer on the donated execution slot, including its timer. */
	CHECK(wump_blocking(native_read, &ctx) == 0);
	CHECK(ctx.result == 1 && ctx.byte == 'b');
	puts("blocking read completed while another task ran on one slot");
	CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	CHECK(close(ctx.fd[0]) == 0 && close(ctx.fd[1]) == 0);
	wump_chan_free(ctx.done);
}

int main(void) {
	return wump_run(program, NULL, 1) == 0 ? 0 : 1;
}
