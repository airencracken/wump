#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "wump.h"

#define SECOND INT64_C(1000000000)
#define CHECK(expr) do { if (!(expr)) { perror(#expr); exit(1); } } while (0)

typedef struct echo_arg { wump_io *io; wump_chan *done; } echo_arg;
static const char message[] = "hello through epoll";

static void write_all(wump_io *io, const char *data, size_t size) {
	for (size_t offset = 0; offset < size;) {
		ssize_t n = wump_io_write(io, data + offset, size - offset, SECOND);
		CHECK(n > 0);
		offset += (size_t)n;
	}
}

static void server(void *arg) {
	echo_arg *ctx = arg;
	char data[sizeof(message)];
	for (size_t offset = 0; offset < sizeof(data);) {
		ssize_t n = wump_io_read(ctx->io, data + offset, sizeof(data) - offset, SECOND);
		CHECK(n > 0);
		offset += (size_t)n;
	}
	write_all(ctx->io, data, sizeof(data));
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void program(void *arg) {
	(void)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *client = wump_io_open(fd[0]), *connection = wump_io_open(fd[1]);
	CHECK(client != NULL && connection != NULL);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	echo_arg ctx = { connection, done };
	CHECK(wump_go(server, &ctx) == 0);
	write_all(client, message, sizeof(message));
	char reply[sizeof(message)];
	for (size_t offset = 0; offset < sizeof(reply);) {
		ssize_t n = wump_io_read(client, reply + offset, sizeof(reply) - offset, SECOND);
		CHECK(n > 0);
		offset += (size_t)n;
	}
	CHECK(memcmp(message, reply, sizeof(message)) == 0);
	printf("echo: %s\n", reply);
	CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(client) == 0 && wump_io_free(connection) == 0);
	wump_chan_free(done);
}

int main(void) {
	/* A single worker proves that a parked read leaves room for its peer. */
	return wump_run(program, NULL, 1) == 0 ? 0 : 1;
}
