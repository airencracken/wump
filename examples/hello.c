#include <stdio.h>
#include <stdlib.h>
#include "wump.h"

static void fail(const char *operation) {
	perror(operation);
	exit(1);
}

static void worker(void *arg) {
	wump_chan *results = arg;
	int value = 42;
	if (wump_chan_send(results, &value) != 0) {
		fail("send");
	}
}

static void program(void *arg) {
	(void)arg;
	wump_chan *results = wump_chan_make(sizeof(int), 0);
	if (results == NULL || wump_go(worker, results) != 0) {
		fail("spawn");
	}
	int value;
	if (wump_chan_recv(results, &value) != 1) {
		fail("receive");
	}
	printf("received %d on worker %d of %d\n", value,
		wump_worker_id(), wump_nprocs());
	wump_chan_free(results);
}

int main(void) {
	if (wump_run(program, NULL, 0) != 0) {
		fail("runtime");
	}
	return 0;
}
