#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
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

extern int wump_test_get_errno(void);
#define CHECK(expr) do { if (!(expr)) { \
	fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, wump_test_get_errno()); abort(); \
} } while (0)
#define MS INT64_C(1000000)
#define SECOND INT64_C(1000000000)

static void pair(wump_io **a, wump_io **b) {
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	*a = wump_io_open(fd[0]);
	*b = wump_io_open(fd[1]);
	CHECK(*a != NULL && *b != NULL);
}

static void read_all(wump_io *io, void *buf, size_t size) {
	size_t offset = 0;
	while (offset < size) {
		ssize_t n = wump_io_read(io, (char *)buf + offset, size - offset, 5 * SECOND);
		CHECK(n > 0);
		offset += (size_t)n;
	}
}

static void write_all(wump_io *io, const void *buf, size_t size) {
	size_t offset = 0;
	while (offset < size) {
		ssize_t n = wump_io_write(io, (const char *)buf + offset, size - offset, 5 * SECOND);
		CHECK(n > 0);
		offset += (size_t)n;
	}
}

static void api_program(void *arg) {
	(void)arg;
	CHECK(wump_io_open(-1) == NULL && wump_test_get_errno() == EBADF);
	wump_io *a, *b;
	pair(&a, &b);
	int fd = wump_io_fd(a);
	CHECK(fd >= 0);
	CHECK((fcntl(fd, F_GETFL, 0) & O_NONBLOCK) != 0);
	CHECK((fcntl(fd, F_GETFD, 0) & FD_CLOEXEC) != 0);
	CHECK(wump_io_open(fd) == NULL && wump_test_get_errno() == EEXIST);
	CHECK(wump_io_wait(a, 0, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_wait(a, 4, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_wait(a, WUMP_IO_READ, -2) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_wait(a, WUMP_IO_READ, INT64_MAX) == -1 && wump_test_get_errno() == EOVERFLOW);
	CHECK(wump_io_wait(a, WUMP_IO_READ, 0) == 0);
	CHECK(wump_io_wait(a, WUMP_IO_WRITE, 0) == WUMP_IO_WRITE);
	CHECK(wump_io_wait(a, WUMP_IO_READ | WUMP_IO_WRITE, 0) == WUMP_IO_WRITE);
	CHECK(wump_io_read(a, NULL, 1, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_write(a, NULL, 1, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_read(a, &fd, SIZE_MAX, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_read(a, NULL, 0, 0) == 0);
	CHECK(wump_io_write(a, NULL, 0, 0) == 0);
	char value = '?';
	CHECK(wump_io_read(a, &value, 1, 0) == -1 && wump_test_get_errno() == ETIMEDOUT);
	CHECK(value == '?');
	int64_t before = wump_now();
	CHECK(wump_io_wait(a, WUMP_IO_READ, MS) == 0);
	CHECK(wump_now() - before >= MS);
	CHECK(wump_io_write(b, "x", 1, 0) == 1);
	CHECK(wump_io_wait(a, WUMP_IO_READ, 0) == WUMP_IO_READ);
	CHECK(wump_io_read(a, &value, 1, 0) == 1 && value == 'x');
	CHECK(wump_io_accept(a, (struct sockaddr *)&fd, NULL, 0) == NULL && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_connect(a, NULL, 0, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_close(a) == 0);
	CHECK(wump_io_close(a) == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_io_fd(a) == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_io_read(a, &value, 1, 0) == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_io_free(a) == 0);
	CHECK(fcntl(fd, F_GETFD, 0) == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_io_free(b) == 0);
	fd = open("/dev/null", O_RDONLY);
	CHECK(fd >= 0);
	int flags = fcntl(fd, F_GETFL, 0), fdflags = fcntl(fd, F_GETFD, 0);
	CHECK(wump_io_open(fd) == NULL && wump_test_get_errno() == EPERM);
	CHECK(fcntl(fd, F_GETFL, 0) == flags && fcntl(fd, F_GETFD, 0) == fdflags);
	CHECK(close(fd) == 0);
}

static void test_api(void) {
	CHECK(wump_io_open(-1) == NULL && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_free(NULL) == 0);
	CHECK(wump_io_close(NULL) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_fd(NULL) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_io_wait(NULL, WUMP_IO_READ, 0) == -1 && wump_test_get_errno() == EINVAL);
	CHECK(wump_run(api_program, NULL, 1) == 0);
	CHECK(wump_run(api_program, NULL, 4) == 0);
}

typedef struct external_arg { int fd[2]; } external_arg;

static void *external_writer(void *arg) {
	external_arg *ctx = arg;
	struct timespec delay = { .tv_nsec = 5 * MS };
	while (nanosleep(&delay, &delay) != 0) {
		CHECK(wump_test_get_errno() == EINTR);
	}
	CHECK(write(ctx->fd[1], "e", 1) == 1);
	return NULL;
}

static void external_program(void *arg) {
	external_arg *ctx = arg;
	wump_io *io = wump_io_open(ctx->fd[0]);
	CHECK(io != NULL);
	char value;
	CHECK(wump_io_read(io, &value, 1, -1) == 1 && value == 'e');
	CHECK(wump_io_free(io) == 0);
}

static void test_external(void) {
	for (int n = 1; n <= 4; n *= 4) {
		external_arg ctx;
		CHECK(pipe(ctx.fd) == 0);
		pthread_t thread;
		CHECK(pthread_create(&thread, NULL, external_writer, &ctx) == 0);
		CHECK(wump_run(external_program, &ctx, n) == 0);
		CHECK(pthread_join(thread, NULL) == 0);
		CHECK(close(ctx.fd[1]) == 0);
	}
}

typedef struct io_arg {
	wump_io *io, *peer;
	wump_chan *done;
	int writing, expected, index;
} io_arg;

static void close_waiter(void *arg) {
	io_arg *ctx = arg;
	char value = 'w';
	ssize_t n = ctx->writing ? wump_io_write(ctx->io, &value, 1, -1) :
		wump_io_read(ctx->io, &value, 1, -1);
	CHECK(n == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static size_t fill(wump_io *io) {
	char data[4096] = {0};
	size_t total = 0;
	ssize_t n;
	while ((n = wump_io_write(io, data, sizeof(data), 0)) >= 0) {
		total += (size_t)n;
	}
	CHECK(wump_test_get_errno() == ETIMEDOUT);
	return total;
}

static void close_program(void *arg) {
	(void)arg;
	wump_io *a, *b;
	pair(&a, &b);
	fill(a);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	io_arg args[] = { { .io = a, .done = done }, { .io = a, .done = done, .writing = 1 } };
	CHECK(wump_go(close_waiter, &args[0]) == 0 && wump_go(close_waiter, &args[1]) == 0);
	wump_yield();
	CHECK(wump_io_wait(a, WUMP_IO_READ, 0) == -1 && wump_test_get_errno() == EBUSY);
	CHECK(wump_io_wait(a, WUMP_IO_WRITE, 0) == -1 && wump_test_get_errno() == EBUSY);
	CHECK(wump_io_free(a) == -1 && wump_test_get_errno() == EBUSY);
	CHECK(wump_io_close(a) == 0);
	CHECK(wump_io_free(a) == -1 && wump_test_get_errno() == EBUSY);
	CHECK(wump_chan_recv(done, NULL) == 1 && wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(a) == 0 && wump_io_free(b) == 0);
	wump_chan_free(done);
}

static void test_close(void) {
	CHECK(wump_run(close_program, NULL, 1) == 0);
}

static void combined_waiter(void *arg) {
	io_arg *ctx = arg;
	CHECK(wump_io_wait(ctx->io, WUMP_IO_READ | WUMP_IO_WRITE, -1) == -1);
	CHECK(wump_test_get_errno() == EBADF);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void combined_program(void *arg) {
	(void)arg;
	wump_io *a, *b;
	pair(&a, &b);
	fill(a);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	io_arg ctx = { .io = a, .done = done };
	CHECK(wump_go(combined_waiter, &ctx) == 0);
	wump_yield();
	CHECK(wump_io_close(a) == 0);
	CHECK(wump_io_free(a) == -1 && wump_test_get_errno() == EBUSY);
	CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(a) == 0 && wump_io_free(b) == 0);
	wump_chan_free(done);
}

static void test_combined(void) {
	CHECK(wump_run(combined_program, NULL, 1) == 0);
}

static void duplex_waiter(void *arg) {
	io_arg *ctx = arg;
	char value = ctx->writing ? 'w' : '?';
	ssize_t n = ctx->writing ? wump_io_write(ctx->io, &value, 1, -1) :
		wump_io_read(ctx->io, &value, 1, -1);
	CHECK(n == 1 && value == (ctx->writing ? 'w' : 'r'));
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void duplex_program(void *arg) {
	(void)arg;
	wump_io *a, *b;
	pair(&a, &b);
	size_t filled = fill(a);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	io_arg args[] = { { .io = a, .done = done }, { .io = a, .done = done, .writing = 1 } };
	CHECK(wump_go(duplex_waiter, &args[0]) == 0 && wump_go(duplex_waiter, &args[1]) == 0);
	wump_yield();
	char data[8192];
	while (filled != 0) {
		ssize_t n = wump_io_read(b, data, filled < sizeof(data) ? filled : sizeof(data), SECOND);
		CHECK(n > 0);
		filled -= (size_t)n;
	}
	CHECK(wump_io_write(b, "r", 1, SECOND) == 1);
	CHECK(wump_chan_recv(done, NULL) == 1 && wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(a) == 0 && wump_io_free(b) == 0);
	wump_chan_free(done);
}

static void test_duplex(void) {
	CHECK(wump_run(duplex_program, NULL, 1) == 0);
	CHECK(wump_run(duplex_program, NULL, 4) == 0);
}

typedef struct packet { uint64_t index, sequence; unsigned char data[511]; } packet;

static void echo_worker(void *arg) {
	io_arg *ctx = arg;
	for (int i = 0; i < 200; i++) {
		packet value;
		read_all(ctx->io, &value, sizeof(value));
		CHECK(value.index == (uint64_t)ctx->index && value.sequence == (uint64_t)i);
		for (size_t j = 0; j < sizeof(value.data); j++) {
			CHECK(value.data[j] == (unsigned char)(i + ctx->index));
		}
		write_all(ctx->io, &value, sizeof(value));
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void echo_client(void *arg) {
	io_arg *ctx = arg;
	for (int i = 0; i < 200; i++) {
		packet sent, received;
		memset(&sent, 0, sizeof(sent));
		sent.index = (uint64_t)ctx->index;
		sent.sequence = (uint64_t)i;
		memset(sent.data, (unsigned char)(i + ctx->index), sizeof(sent.data));
		write_all(ctx->io, &sent, sizeof(sent));
		read_all(ctx->io, &received, sizeof(received));
		CHECK(memcmp(&sent, &received, sizeof(sent)) == 0);
	}
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void echo_program(void *arg) {
	(void)arg;
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	io_arg args[32];
	for (int i = 0; i < 16; i++) {
		wump_io *a, *b;
		pair(&a, &b);
		args[i * 2] = (io_arg){ .io = a, .done = done, .index = i };
		args[i * 2 + 1] = (io_arg){ .io = b, .done = done, .index = i };
		CHECK(wump_go(echo_client, &args[i * 2]) == 0);
		CHECK(wump_go(echo_worker, &args[i * 2 + 1]) == 0);
	}
	for (int i = 0; i < 32; i++) {
		CHECK(wump_chan_recv(done, NULL) == 1);
	}
	for (int i = 0; i < 32; i++) {
		CHECK(wump_io_free(args[i].io) == 0);
	}
	wump_chan_free(done);
}

static void test_echo(void) {
	for (int n = 1; n <= 16; n *= 4) {
		CHECK(wump_run(echo_program, NULL, n) == 0);
	}
}

static void delayed_writer(void *arg) {
	io_arg *ctx = arg;
	CHECK(wump_sleep((ctx->index % 3) * 1000) == 0);
	CHECK(wump_io_write(ctx->io, "t", 1, SECOND) == 1);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void race_program(void *arg) {
	(void)arg;
	for (int i = 0; i < 300; i++) {
		wump_io *a, *b;
		pair(&a, &b);
		wump_chan *done = wump_chan_make(0, 0);
		CHECK(done != NULL);
		io_arg ctx = { .io = b, .done = done, .index = i };
		CHECK(wump_go(delayed_writer, &ctx) == 0);
		char value = '?';
		ssize_t n = wump_io_read(a, &value, 1, i % 2 ? 1 : 10000);
		CHECK(n == 1 || (n == -1 && wump_test_get_errno() == ETIMEDOUT));
		CHECK(wump_chan_recv(done, NULL) == 1);
		if (n == -1) {
			CHECK(value == '?');
			CHECK(wump_io_read(a, &value, 1, SECOND) == 1);
		}
		CHECK(value == 't' && wump_io_wait(a, WUMP_IO_READ, 0) == 0);
		CHECK(wump_io_free(a) == 0 && wump_io_free(b) == 0);
		wump_chan_free(done);
	}
}

static void test_races(void) {
	for (int n = 1; n <= 16; n *= 4) {
		CHECK(wump_run(race_program, NULL, n) == 0);
	}
}

static void eof_program(void *arg) {
	(void)arg;
	wump_io *a, *b;
	pair(&a, &b);
	CHECK(wump_io_write(b, "end", 3, 0) == 3);
	CHECK(shutdown(wump_io_fd(b), SHUT_WR) == 0);
	char data[8];
	CHECK(wump_io_wait(a, WUMP_IO_READ, SECOND) == WUMP_IO_READ);
	CHECK(wump_io_read(a, data, sizeof(data), SECOND) == 3 && memcmp(data, "end", 3) == 0);
	CHECK(wump_io_read(a, data, sizeof(data), SECOND) == 0);
	CHECK(wump_io_wait(a, WUMP_IO_READ, 0) == WUMP_IO_READ);
	CHECK(wump_io_free(b) == 0);
	CHECK(wump_io_read(a, data, sizeof(data), SECOND) == 0);
	CHECK(wump_io_write(a, "x", 1, SECOND) == -1 && wump_test_get_errno() == EPIPE);
	CHECK(wump_io_free(a) == 0);
}

static void test_eof(void) {
	CHECK(wump_run(eof_program, NULL, 4) == 0);
}

static void close_peer(void *arg) {
	io_arg *ctx = arg;
	CHECK(wump_sleep(MS) == 0);
	CHECK(wump_io_free(ctx->io) == 0);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void peer_program(void *arg) {
	(void)arg;
	wump_io *a, *b;
	pair(&a, &b);
	CHECK(wump_io_write(b, "end", 3, 0) == 3);
	CHECK(wump_io_free(b) == 0);
	char data[8];
	CHECK(wump_io_read(a, data, sizeof(data), SECOND) == 3 && memcmp(data, "end", 3) == 0);
	CHECK(wump_io_read(a, data, sizeof(data), SECOND) == 0);
	CHECK(wump_io_write(a, "x", 1, 0) == -1 && wump_test_get_errno() == EPIPE);
	CHECK(wump_io_free(a) == 0);
	pair(&a, &b);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	io_arg ctx = { .io = b, .done = done };
	CHECK(wump_go(close_peer, &ctx) == 0);
	CHECK(wump_io_read(a, data, sizeof(data), -1) == 0);
	CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(a) == 0);
	wump_chan_free(done);
}

static void test_peer(void) {
	CHECK(wump_run(peer_program, NULL, 1) == 0);
	CHECK(wump_run(peer_program, NULL, 4) == 0);
}

static void tcp_client(void *arg) {
	struct sockaddr_in *addr = arg;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(fd >= 0);
	wump_io *io = wump_io_open(fd);
	CHECK(io != NULL);
	CHECK(wump_io_connect(io, (struct sockaddr *)addr, sizeof(*addr), SECOND) == 0);
	write_all(io, "ping", 4);
	char data[4];
	read_all(io, data, sizeof(data));
	CHECK(memcmp(data, "pong", 4) == 0);
	CHECK(wump_io_free(io) == 0);
}

static void tcp_program(void *arg) {
	(void)arg;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(fd >= 0);
	struct sockaddr_in addr = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
	CHECK(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
	socklen_t len = sizeof(addr);
	CHECK(getsockname(fd, (struct sockaddr *)&addr, &len) == 0);
	CHECK(listen(fd, 16) == 0);
	wump_io *listener = wump_io_open(fd);
	CHECK(listener != NULL);
	CHECK(wump_io_accept(listener, NULL, NULL, 0) == NULL && wump_test_get_errno() == ETIMEDOUT);
	CHECK(wump_go(tcp_client, &addr) == 0);
	struct sockaddr_storage peer;
	len = sizeof(peer);
	wump_io *accepted = wump_io_accept(listener, (struct sockaddr *)&peer, &len, SECOND);
	CHECK(accepted != NULL && peer.ss_family == AF_INET);
	fd = wump_io_fd(accepted);
	CHECK((fcntl(fd, F_GETFL, 0) & O_NONBLOCK) != 0 && (fcntl(fd, F_GETFD, 0) & FD_CLOEXEC) != 0);
	char data[4];
	read_all(accepted, data, sizeof(data));
	CHECK(memcmp(data, "ping", 4) == 0);
	write_all(accepted, "pong", 4);
	/* EOF joins the client after its final write/read and close. */
	CHECK(wump_io_read(accepted, data, sizeof(data), SECOND) == 0);
	CHECK(wump_io_free(accepted) == 0 && wump_io_free(listener) == 0);
	fd = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(fd >= 0);
	addr.sin_port = 0;
	CHECK(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
	len = sizeof(addr);
	CHECK(getsockname(fd, (struct sockaddr *)&addr, &len) == 0);
	int client = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(client >= 0);
	wump_io *io = wump_io_open(client);
	CHECK(io != NULL);
	CHECK(wump_io_connect(io, (struct sockaddr *)&addr, sizeof(addr), SECOND) == -1);
	CHECK(wump_test_get_errno() == ECONNREFUSED);
	CHECK(wump_io_free(io) == 0 && close(fd) == 0);
}

static void test_tcp(void) {
	CHECK(wump_run(tcp_program, NULL, 1) == 0);
	CHECK(wump_run(tcp_program, NULL, 4) == 0);
}

static int count_fds(void) {
	DIR *dir = opendir("/proc/self/fd");
	CHECK(dir != NULL);
	int n = 0;
	struct dirent *entry;
	while ((entry = readdir(dir)) != NULL) {
		if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
			n++;
		}
	}
	CHECK(closedir(dir) == 0);
	return n;
}

typedef struct abandoned_arg { int own[32], peer[32], ready; } abandoned_arg;

static void abandoned_reader(void *arg) {
	char byte;
	CHECK(wump_io_read(arg, &byte, 1, -1) == 1);
}

static void abandon_program(void *arg) {
	abandoned_arg *ctx = arg;
	for (int i = 0; i < 32; i++) {
		int fd[2];
		CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
		ctx->own[i] = fd[0];
		ctx->peer[i] = fd[1];
		wump_io *io = wump_io_open(fd[0]);
		CHECK(io != NULL && wump_go(abandoned_reader, io) == 0);
	}
	wump_yield();
	if (ctx->ready) {
		for (int i = 0; i < 32; i++) {
			CHECK(write(ctx->peer[i], "x", 1) == 1);
		}
	}
}

static void test_abandon(void) {
	int before = count_fds();
	for (int repeat = 0; repeat < 10; repeat++) {
		abandoned_arg ctx = { .ready = repeat % 2 };
		CHECK(wump_run(abandon_program, &ctx, 1) == 0);
		for (int i = 0; i < 32; i++) {
			CHECK(fcntl(ctx.own[i], F_GETFD, 0) == -1 && wump_test_get_errno() == EBADF);
			CHECK(close(ctx.peer[i]) == 0);
		}
		CHECK(count_fds() == before);
	}
}

static void idle_program(void *arg) {
	wump_io *a, *b;
	pair(&a, &b);
	CHECK(wump_io_wait(a, WUMP_IO_READ, MS) == 0);
	CHECK(wump_io_free(a) == 0 && wump_io_free(b) == 0);
	CHECK(wump_chan_recv(arg, NULL) == 1);
}

static void test_deadlock(void) {
	wump_chan *ch = wump_chan_make(0, 0);
	CHECK(ch != NULL);
	CHECK(wump_run(idle_program, ch, 4) == -1 && wump_test_get_errno() == EDEADLK);
	wump_chan_free(ch);
}

static void foreign_program(void *arg) {
	CHECK(wump_io_wait(arg, WUMP_IO_READ, 0) == -1 && wump_test_get_errno() == EXDEV);
	CHECK(wump_io_close(arg) == -1 && wump_test_get_errno() == EXDEV);
	CHECK(wump_io_free(arg) == -1 && wump_test_get_errno() == EXDEV);
}

static void *foreign_thread(void *arg) {
	CHECK(wump_run(foreign_program, arg, 1) == 0);
	return NULL;
}

static void owner_program(void *arg) {
	(void)arg;
	wump_io *a, *b;
	pair(&a, &b);
	pthread_t thread;
	CHECK(pthread_create(&thread, NULL, foreign_thread, a) == 0);
	CHECK(pthread_join(thread, NULL) == 0);
	CHECK(wump_io_free(a) == 0 && wump_io_free(b) == 0);
}

static void *independent_thread(void *arg) {
	(void)arg;
	CHECK(wump_run(race_program, NULL, 2) == 0);
	return NULL;
}

static void test_ownership(void) {
	CHECK(wump_run(owner_program, NULL, 1) == 0);
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
	CHECK(signal(SIGPIPE, SIG_IGN) != SIG_ERR);
	test_case tests[] = {
		{ "I/O API, ownership transfer, and flag rollback", test_api },
		{ "external pipe readiness while every worker is idle", test_external },
		{ "close interrupts both directions and free rejects active users", test_close },
		{ "combined readiness wait closes exactly once", test_combined },
		{ "independent read/write waits rearm one-shot epoll", test_duplex },
		{ "parallel echo integrity and partial transfers", test_echo },
		{ "timeout, readiness, and descriptor reuse races", test_races },
		{ "peer close drains bytes, EOF, and EPIPE", test_peer },
		{ "EOF, half-close, and broken-pipe errors", test_eof },
		{ "loopback TCP accept, connect, and connection refusal", test_tcp },
		{ "shutdown joins poller, detaches waits, and closes descriptors", test_abandon },
		{ "deadlock detection after I/O timeout cleanup", test_deadlock },
		{ "runtime ownership and independent pollers", test_ownership }
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
