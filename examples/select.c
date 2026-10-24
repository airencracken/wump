#include <stdio.h>
#include <stdlib.h>

#include "wump.h"

#define MS INT64_C(1000000)
#define CHECK(expr) do { if (!(expr)) { perror(#expr); exit(1); } } while (0)

typedef struct channels { wump_chan *results, *done; } channels;

static void worker(void *arg) {
	channels *ctx = arg;
	CHECK(wump_sleep(10 * MS) == 0);
	int value = 42;
	wump_case send = { ctx->results, WUMP_SEND, &value, 0 };
	CHECK(wump_sel(&send, 1, 100 * MS, NULL) >= 0);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void program(void *arg) {
	(void)arg;
	channels ctx = { wump_chan_make(sizeof(int), 0), wump_chan_make(0, 0) };
	CHECK(ctx.results != NULL && ctx.done != NULL);
	CHECK(wump_go(worker, &ctx) == 0);
	int value;
	wump_case recv = { ctx.results, WUMP_RECV, &value, 0 };
	int result = wump_sel(&recv, 1, 50 * MS, NULL);
	CHECK(result >= 0);
	if (result == 1) {
		CHECK(recv.result == 1);
		printf("received %d before the timeout\n", value);
	} else {
		puts("receive timed out");
	}
	/* Join before freeing channels, including when receive times out. */
	CHECK(wump_chan_recv(ctx.done, NULL) == 1);
	wump_chan_free(ctx.results);
	wump_chan_free(ctx.done);
}

int main(void) {
	return wump_run(program, NULL, 0) == 0 ? 0 : 1;
}
