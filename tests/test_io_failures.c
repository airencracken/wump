#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include "internal.h"

extern int wump_test_get_errno(void);
#define CHECK(expr) do { if (!(expr)) { \
	fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, wump_test_get_errno()); abort(); \
} } while (0)

enum operation { NONE, CALLOC, REALLOC, MUTEX, THREAD, EPOLL, EVENTFD, ADD, MOD, DEL, WAIT, FCNTL, POLL, READ, WRITE, CLOSE };
static atomic_int failure, countdown, injected_errno, target_fd;
static atomic_int accepted_fd = ATOMIC_VAR_INIT(-1);
static atomic_int fake_connect, connection_error, peer_pending;
static atomic_int read_armed;
static atomic_int pause_events, captured_event, stale_phase, new_read_armed, stale_fd;

static void arm(enum operation op, int nth, int error, int fd) {
	atomic_store(&countdown, nth);
	atomic_store(&injected_errno, error);
	atomic_store(&target_fd, fd);
	atomic_store(&failure, op);
}

static int fail(enum operation op, int fd) {
	if (atomic_load(&failure) != (int)op ||
		(atomic_load(&target_fd) >= 0 && atomic_load(&target_fd) != fd)) {
		return 0;
	}
	if (atomic_fetch_sub(&countdown, 1) != 1) {
		return 0;
	}
	atomic_store(&failure, NONE);
	errno = atomic_load(&injected_errno);
	return 1;
}

void *__real_calloc(size_t, size_t);
void *__wrap_calloc(size_t n, size_t size) {
	return fail(CALLOC, -1) ? NULL : __real_calloc(n, size);
}
void *__real_realloc(void *, size_t);
void *__wrap_realloc(void *p, size_t n) {
	return fail(REALLOC, -1) ? NULL : __real_realloc(p, n);
}
int __real_pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int __wrap_pthread_mutex_init(pthread_mutex_t *mu, const pthread_mutexattr_t *attr) {
	return fail(MUTEX, -1) ? atomic_load(&injected_errno) : __real_pthread_mutex_init(mu, attr);
}
int __real_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*fn)(void *), void *arg) {
	return fail(THREAD, -1) ? atomic_load(&injected_errno) : __real_pthread_create(thread, attr, fn, arg);
}
int __real_epoll_create1(int);
int __wrap_epoll_create1(int flags) {
	return fail(EPOLL, -1) ? -1 : __real_epoll_create1(flags);
}
int __real_eventfd(unsigned, int);
int __wrap_eventfd(unsigned value, int flags) {
	return fail(EVENTFD, -1) ? -1 : __real_eventfd(value, flags);
}
int __real_epoll_ctl(int, int, int, struct epoll_event *);
int __wrap_epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
	enum operation mode = op == EPOLL_CTL_ADD ? ADD : op == EPOLL_CTL_MOD ? MOD : DEL;
	int result = fail(mode, fd) ? -1 : __real_epoll_ctl(epfd, op, fd, event);
	if (result == 0 && op == EPOLL_CTL_MOD && atomic_load(&failure) == READ &&
		atomic_load(&target_fd) == fd) {
		atomic_store(&read_armed, 1);
	}
	if (result == 0 && op == EPOLL_CTL_MOD && atomic_load(&stale_phase) == 2 &&
		atomic_load(&stale_fd) == fd) {
		atomic_store(&new_read_armed, 1);
	}
	return result;
}
int __real_epoll_wait(int, struct epoll_event *, int, int);
int __wrap_epoll_wait(int epfd, struct epoll_event *events, int n, int timeout) {
	if (atomic_load(&injected_errno) == EINTR && fail(WAIT, -1)) {
		return -1;
	}
	int result = __real_epoll_wait(epfd, events, n, timeout);
	if (result > 0 && atomic_load(&pause_events)) {
		for (int i = 0; i < result; i++) {
			if (events[i].data.u64 != 0) {
				atomic_store(&captured_event, 1);
				while (atomic_load(&pause_events)) {
					sched_yield();
				}
				break;
			}
		}
	}
	return atomic_load(&injected_errno) != EINTR && fail(WAIT, -1) ? -1 : result;
}
int __real_fcntl(int, int, ...);
int __wrap_fcntl(int fd, int op, ...) {
	va_list args;
	va_start(args, op);
	int value = va_arg(args, int);
	va_end(args);
	return fail(FCNTL, fd) ? -1 : __real_fcntl(fd, op, value);
}
int __real_poll(struct pollfd *, nfds_t, int);
int __wrap_poll(struct pollfd *fds, nfds_t n, int timeout) {
	return fail(POLL, n ? fds[0].fd : -1) ? -1 : __real_poll(fds, n, timeout);
}
#ifdef __GLIBC__
/* Fortified builds call these entry points instead of poll/read. Keep
 * their real bounds checks while injecting the same syscall failures. */
int __real___poll_chk(struct pollfd *, nfds_t, int, size_t);
int __wrap___poll_chk(struct pollfd *fds, nfds_t n, int timeout, size_t bytes) {
	return fail(POLL, n ? fds[0].fd : -1) ? -1 : __real___poll_chk(fds, n, timeout, bytes);
}
ssize_t __real___read_chk(int, void *, size_t, size_t);
ssize_t __wrap___read_chk(int fd, void *buf, size_t n, size_t bytes) {
	return fail(READ, fd) ? -1 : __real___read_chk(fd, buf, n, bytes);
}
#endif
ssize_t __real_read(int, void *, size_t);
ssize_t __wrap_read(int fd, void *buf, size_t n) {
	return fail(READ, fd) ? -1 : __real_read(fd, buf, n);
}
ssize_t __real_write(int, const void *, size_t);
ssize_t __wrap_write(int fd, const void *buf, size_t n) {
	return fail(WRITE, fd) ? -1 : __real_write(fd, buf, n);
}
int __real_close(int);
int __wrap_close(int fd) {
	if (fail(CLOSE, fd)) {
		CHECK(__real_close(fd) == 0); /* Linux closes even on EINTR. */
		errno = atomic_load(&injected_errno);
		return -1;
	}
	return __real_close(fd);
}
int __real_accept4(int, struct sockaddr *, socklen_t *, int);
int __wrap_accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags) {
	int accepted = atomic_exchange(&accepted_fd, -1);
	return accepted >= 0 ? accepted : __real_accept4(fd, addr, len, flags);
}
int __real_connect(int, const struct sockaddr *, socklen_t);
int __wrap_connect(int fd, const struct sockaddr *addr, socklen_t len) {
	if (atomic_load(&fake_connect)) {
		errno = EINPROGRESS;
		return -1;
	}
	return __real_connect(fd, addr, len);
}
int __real_getsockopt(int, int, int, void *, socklen_t *);
int __wrap_getsockopt(int fd, int level, int option, void *value, socklen_t *len) {
	if (atomic_load(&fake_connect) && level == SOL_SOCKET && option == SO_ERROR) {
		CHECK(*len >= sizeof(int));
		*(int *)value = atomic_load(&connection_error);
		*len = sizeof(int);
		return 0;
	}
	return __real_getsockopt(fd, level, option, value, len);
}
int __real_getpeername(int, struct sockaddr *, socklen_t *);
int __wrap_getpeername(int fd, struct sockaddr *addr, socklen_t *len) {
	if (atomic_load(&fake_connect)) {
		int pending = atomic_load(&peer_pending);
		if (pending != 0) {
			if (pending > 0) {
				atomic_fetch_sub(&peer_pending, 1);
			}
			errno = ENOTCONN;
			return -1;
		}
		(void)addr;
		(void)len;
		return 0;
	}
	return __real_getpeername(fd, addr, len);
}

static int count_fds(void) {
	DIR *dir = opendir("/proc/self/fd");
	CHECK(dir != NULL);
	int count = 0;
	struct dirent *entry;
	while ((entry = readdir(dir)) != NULL) {
		if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
			count++;
		}
	}
	CHECK(closedir(dir) == 0);
	return count;
}

typedef struct attach_failure { enum operation op; int nth, error; } attach_failure;

static void attach_program(void *arg) {
	attach_failure *test = arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	int flags = fcntl(fd[0], F_GETFL, 0), fdflags = fcntl(fd[0], F_GETFD, 0);
	arm(test->op, test->nth, test->error, -1);
	CHECK(wump_io_open(fd[0]) == NULL && wump_test_get_errno() == test->error);
	CHECK(atomic_load(&failure) == NONE);
	CHECK(fcntl(fd[0], F_GETFL, 0) == flags && fcntl(fd[0], F_GETFD, 0) == fdflags);
	wump_io *io = wump_io_open(fd[0]);
	CHECK(io != NULL);
	CHECK(wump_io_free(io) == 0 && close(fd[1]) == 0);
}

static void waiter_program(void *arg) {
	(void)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *io = wump_io_open(fd[0]);
	CHECK(io != NULL);
	arm(MOD, 1, EIO, fd[0]);
	CHECK(wump_io_wait(io, WUMP_IO_READ, -1) == -1 && wump_test_get_errno() == EIO);
	arm(REALLOC, 1, ENOMEM, -1);
	CHECK(wump_io_wait(io, WUMP_IO_READ, INT64_C(1000000000)) == -1 && wump_test_get_errno() == ENOMEM);
	CHECK(wump_io_wait(io, WUMP_IO_READ, 1) == 0);
	arm(POLL, 1, EINTR, fd[0]);
	CHECK(wump_io_wait(io, WUMP_IO_READ, 0) == 0);
	arm(POLL, 1, EIO, fd[0]);
	CHECK(wump_io_wait(io, WUMP_IO_READ, 0) == -1 && wump_test_get_errno() == EIO);
	arm(WRITE, 1, EINTR, fd[0]);
	CHECK(wump_io_write(io, "w", 1, -1) == 1);
	char byte;
	CHECK(read(fd[1], &byte, 1) == 1 && byte == 'w');
	CHECK(write(fd[1], "r", 1) == 1);
	arm(READ, 1, EINTR, fd[0]);
	CHECK(wump_io_read(io, &byte, 1, -1) == 1 && byte == 'r');
	arm(DEL, 1, EIO, fd[0]);
	CHECK(wump_io_close(io) == -1 && wump_test_get_errno() == EIO);
	CHECK(fcntl(fd[0], F_GETFD, 0) == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_io_free(io) == 0 && close(fd[1]) == 0);
}

typedef struct wake_arg { int peer; wump_chan *done; int wait_arm; } wake_arg;

static void wake_reader(void *arg) {
	wake_arg *ctx = arg;
	CHECK(wump_sleep(INT64_C(1000000)) == 0);
	while (ctx->wait_arm && !atomic_load(&read_armed)) {
		wump_yield();
	}
	CHECK(write(ctx->peer, "x", 1) == 1);
	CHECK(wump_chan_send(ctx->done, NULL) == 0);
}

static void poller_failure(void *arg) {
	int injected = *(int *)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	arm(WAIT, 1, injected, -1);
	wump_io *io = wump_io_open(fd[0]);
	CHECK(io != NULL);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	wake_arg ctx = { .peer = fd[1], .done = done };
	CHECK(wump_go(wake_reader, &ctx) == 0);
	char byte;
	ssize_t n = wump_io_read(io, &byte, 1, -1);
	if (injected == EINTR) {
		CHECK(n == 1 && byte == 'x');
	} else {
		CHECK(n == -1 && wump_test_get_errno() == injected);
		CHECK(wump_io_wait(io, WUMP_IO_WRITE, 0) == -1 && wump_test_get_errno() == injected);
	}
	CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(io) == 0 && close(fd[1]) == 0);
	wump_chan_free(done);
}

static void retry_after_migration(void *arg) {
	int injected = *(int *)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *io = wump_io_open(fd[0]);
	CHECK(io != NULL);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	wake_arg ctx = { .peer = fd[1], .done = done, .wait_arm = 1 };
	/* First read would block. The resumed read either gets EINTR and
	 * retries, or reports EIO without consuming data. A cached errno
	 * address could mistake EIO for the old worker's EAGAIN. */
	atomic_store(&read_armed, 0);
	arm(READ, 2, injected, fd[0]);
	CHECK(wump_go(wake_reader, &ctx) == 0);
	char byte = '?';
	ssize_t n = wump_io_read(io, &byte, 1, -1);
	if (injected == EINTR) {
		CHECK(n == 1 && byte == 'x');
	} else {
		CHECK(n == -1 && wump_test_get_errno() == injected && byte == '?');
		CHECK(wump_io_read(io, &byte, 1, 0) == 1 && byte == 'x');
	}
	CHECK(atomic_load(&failure) == NONE);
	CHECK(wump_chan_recv(done, NULL) == 1);
	CHECK(wump_io_free(io) == 0 && close(fd[1]) == 0);
	wump_chan_free(done);
}

static void accepted_registration_failure(void *arg) {
	(void)arg;
	int listener_pair[2], accepted_pair[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, listener_pair) == 0);
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, accepted_pair) == 0);
	wump_io *io = wump_io_open(listener_pair[0]);
	CHECK(io != NULL);
	/* Supply accept4's successful syscall result, then fail epoll's
	 * registration. This isolates ownership cleanup from networking. */
	atomic_store(&accepted_fd, accepted_pair[0]);
	arm(ADD, 1, ENOSPC, accepted_pair[0]);
	CHECK(wump_io_accept(io, NULL, NULL, 0) == NULL && wump_test_get_errno() == ENOSPC);
	CHECK(fcntl(accepted_pair[0], F_GETFD, 0) == -1 && wump_test_get_errno() == EBADF);
	CHECK(close(accepted_pair[1]) == 0 && close(listener_pair[1]) == 0);
	CHECK(wump_io_free(io) == 0);
}

static void connect_contract(void *arg) {
	(void)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *io = wump_io_open(fd[0]);
	CHECK(io != NULL);
	struct sockaddr addr = { .sa_family = AF_UNIX };
	atomic_store(&fake_connect, 1);
	atomic_store(&connection_error, 0);
	atomic_store(&peer_pending, 1);
	CHECK(wump_io_connect(io, &addr, sizeof(addr), INT64_C(1000000000)) == 0);
	CHECK(atomic_load(&peer_pending) == 0);
	atomic_store(&connection_error, ECONNREFUSED);
	CHECK(wump_io_connect(io, &addr, sizeof(addr), INT64_C(1000000000)) == -1);
	CHECK(wump_test_get_errno() == ECONNREFUSED);
	atomic_store(&connection_error, 0);
	atomic_store(&peer_pending, -1);
	int64_t before = wump_now();
	CHECK(wump_io_connect(io, &addr, sizeof(addr), INT64_C(1000000)) == -1);
	CHECK(wump_test_get_errno() == ETIMEDOUT && wump_now() - before >= INT64_C(1000000));
	CHECK(wump_io_connect(io, &addr, sizeof(addr), 0) == -1 && wump_test_get_errno() == ETIMEDOUT);
	atomic_store(&fake_connect, 0);
	CHECK(wump_io_free(io) == 0 && close(fd[1]) == 0);
}

static void close_eintr(void *arg) {
	(void)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *io = wump_io_open(fd[0]);
	CHECK(io != NULL);
	arm(CLOSE, 1, EINTR, fd[0]);
	CHECK(wump_io_close(io) == -1 && wump_test_get_errno() == EINTR);
	CHECK(wump_io_fd(io) == -1 && wump_test_get_errno() == EBADF);
	CHECK(wump_io_free(io) == 0);
	CHECK(close(fd[1]) == 0);
}

static void release_events(void *arg) {
	while (!atomic_load(&new_read_armed)) {
		wump_yield();
	}
	atomic_store(&pause_events, 0);
	CHECK(wump_chan_send(arg, NULL) == 0);
}

static void stale_event(void *arg) {
	(void)arg;
	int fd[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
	wump_io *old = wump_io_open(fd[0]);
	CHECK(old != NULL);
	wump_chan *done = wump_chan_make(0, 0);
	CHECK(done != NULL);
	wake_arg wake = { .peer = fd[1], .done = done };
	atomic_store(&captured_event, 0);
	atomic_store(&pause_events, 1);
	CHECK(wump_go(wake_reader, &wake) == 0);
	CHECK(wump_io_wait(old, WUMP_IO_READ, INT64_C(10000000)) == 0);
	CHECK(wump_chan_recv(done, NULL) == 1);
	while (!atomic_load(&captured_event)) {
		wump_yield();
	}
	int oldfd = fd[0];
	CHECK(wump_io_free(old) == 0 && close(fd[1]) == 0);
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0 && fd[0] == oldfd);
	wump_io *fresh = wump_io_open(fd[0]);
	CHECK(fresh != NULL);
	atomic_store(&stale_fd, fd[0]);
	atomic_store(&new_read_armed, 0);
	atomic_store(&stale_phase, 2);
	CHECK(wump_go(release_events, done) == 0);
	/* The kernel batch still contains the old descriptor's READ event.
	 * Deliver it only once the reused fd/registry slot has a new waiter.
	 * Its generation must prevent a false readiness notification. */
	CHECK(wump_io_wait(fresh, WUMP_IO_READ, INT64_C(10000000)) == 0);
	CHECK(wump_chan_recv(done, NULL) == 1);
	atomic_store(&stale_phase, 0);
	CHECK(wump_io_free(fresh) == 0 && close(fd[1]) == 0);
	wump_chan_free(done);
}

static void registry_growth(void *arg) {
	(void)arg;
	wump_io *ios[17];
	int peers[17];
	for (int i = 0; i < 17; i++) {
		int fd[2];
		CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
		peers[i] = fd[1];
		if (i == 16) {
			arm(REALLOC, 1, ENOMEM, -1);
			CHECK(wump_io_open(fd[0]) == NULL && wump_test_get_errno() == ENOMEM);
			CHECK((fcntl(fd[0], F_GETFL, 0) & O_NONBLOCK) == 0);
		}
		ios[i] = wump_io_open(fd[0]);
		CHECK(ios[i] != NULL);
	}
	for (int i = 0; i < 17; i++) {
		CHECK(write(peers[i], "g", 1) == 1);
		char byte;
		CHECK(wump_io_read(ios[i], &byte, 1, 0) == 1 && byte == 'g');
		CHECK(wump_io_free(ios[i]) == 0 && close(peers[i]) == 0);
	}
}

int main(void) {
	CHECK(setvbuf(stdout, NULL, _IOLBF, 0) == 0);
	alarm(60);
	int before = count_fds();
	attach_failure cases[] = {
		{ CALLOC, 1, ENOMEM }, { CALLOC, 2, ENOMEM }, { REALLOC, 1, ENOMEM },
		{ MUTEX, 1, ENOMEM }, { THREAD, 1, EAGAIN }, { EPOLL, 1, EMFILE },
		{ EVENTFD, 1, EMFILE }, { ADD, 1, ENOSPC }, { ADD, 2, ENOSPC },
		{ FCNTL, 1, EIO }, { FCNTL, 2, EIO }, { FCNTL, 3, EIO }, { FCNTL, 4, EIO }
	};
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		CHECK(wump_run(attach_program, &cases[i], 1) == 0);
		CHECK(count_fds() == before);
	}
	puts("ok - poller startup and attachment failures preserve fd ownership and flags");
	CHECK(wump_run(waiter_program, NULL, 1) == 0);
	CHECK(count_fds() == before);
	puts("ok - epoll rearm, poll, and timer failures leave handles reusable");
	int errors[] = { EINTR, EIO };
	for (size_t i = 0; i < sizeof(errors) / sizeof(errors[0]); i++) {
		CHECK(wump_run(poller_failure, &errors[i], 1) == 0);
		CHECK(count_fds() == before);
	}
	puts("ok - poller interruption retries and fatal errors wake pending tasks");
	for (size_t e = 0; e < sizeof(errors) / sizeof(errors[0]); e++) {
		for (int i = 0; i < 100; i++) {
			CHECK(wump_run(retry_after_migration, &errors[e], 4) == 0);
		}
	}
	CHECK(count_fds() == before);
	puts("ok - read retries and errors access errno after task migration");
	CHECK(wump_run(accepted_registration_failure, NULL, 1) == 0);
	CHECK(wump_run(connect_contract, NULL, 1) == 0);
	CHECK(wump_run(close_eintr, NULL, 1) == 0);
	CHECK(wump_run(registry_growth, NULL, 1) == 0);
	CHECK(wump_run(stale_event, NULL, 1) == 0);
	CHECK(count_fds() == before);
	puts("ok - accept ownership, connect completion/deadlines, and close EINTR contracts");
	puts("ok - registry growth rollback and stale-event rejection after fd reuse");
	return 0;
}
