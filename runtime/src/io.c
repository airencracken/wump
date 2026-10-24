#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include "internal.h"

typedef struct io_waiter io_waiter;
typedef struct io_slot {
	wump_io *io;
	uint32_t generation;
	size_t next;
} io_slot;

struct wump_poller {
	pthread_mutex_t mu;
	pthread_t thread;
	wump_runtime *rt;
	int epfd, wakefd, stopping, error;
	io_slot *slots;
	size_t cap, free_slot;
};

struct wump_io {
	wump_poller *poller;
	int fd;
	size_t slot, active;
	uint64_t token;
	io_waiter *reader, *writer;
};

struct io_waiter {
	wump_io *io;
	wump_g *g;
	_Atomic size_t winner;
	wump_timer timer;
	int events, ready, error, registered;
};

static int arm(wump_io *io) {
	uint32_t events = EPOLLET | EPOLLONESHOT;
	if (io->reader != NULL) {
		events |= EPOLLIN | EPOLLRDHUP;
	}
	if (io->writer != NULL) {
		events |= EPOLLOUT;
	}
	struct epoll_event ev = { .events = events, .data.u64 = io->token };
	return epoll_ctl(io->poller->epfd, EPOLL_CTL_MOD, io->fd, &ev);
}

static void unlink_wait(io_waiter *w) {
	wump_io *io = w->io;
	if (io->reader == w) {
		io->reader = NULL;
	}
	if (io->writer == w) {
		io->writer = NULL;
	}
	w->registered = 0;
}

/* Caller holds the poller mutex. A resumed task must acquire that mutex
 * before destroying its waiter, so all accesses remain on saved stacks. */
static void complete(io_waiter *w, int ready, int error) {
	unlink_wait(w);
	size_t expected = WUMP_SEL_PENDING;
	int won = atomic_compare_exchange_strong(&w->winner, &expected,
		error != 0 ? WUMP_SEL_ERROR : 0);
	if (won) {
		w->ready = ready;
		w->error = error;
	}
	wump_io_count(w->io->poller->rt, -1, won ? w->g : NULL);
}

static void fail_waiters(wump_io *io, int error) {
	io_waiter *reader = io->reader;
	io_waiter *writer = io->writer;
	if (reader != NULL) {
		complete(reader, 0, error);
	}
	if (writer != NULL && writer != reader) {
		complete(writer, 0, error);
	}
}

static void *poller_entry(void *arg) {
	wump_poller *p = arg;
	struct epoll_event events[64];
	for (;;) {
		int n = epoll_wait(p->epfd, events, 64, -1);
		int error = wump_errno();
		if (n < 0 && error == EINTR) {
			continue;
		}
		pthread_mutex_lock(&p->mu);
		if (p->stopping) {
			pthread_mutex_unlock(&p->mu);
			return NULL;
		}
		if (n < 0) {
			p->error = error;
			for (size_t i = 0; i < p->cap; i++) {
				if (p->slots[i].io != NULL) {
					fail_waiters(p->slots[i].io, error);
				}
			}
			pthread_mutex_unlock(&p->mu);
			return NULL;
		}
		for (int i = 0; i < n; i++) {
			uint64_t token = events[i].data.u64;
			if (token == 0) {
				uint64_t value;
				ssize_t result;
				do {
					result = read(p->wakefd, &value, sizeof(value));
				} while (result < 0 && wump_errno() == EINTR);
				continue;
			}
			size_t index = (uint32_t)token;
			uint32_t generation = (uint32_t)(token >> 32);
			if (index >= p->cap || p->slots[index].generation != generation) {
				continue;
			}
			wump_io *io = p->slots[index].io;
			if (io == NULL || io->fd < 0) {
				continue;
			}
			uint32_t flags = events[i].events;
			int ready = 0;
			if (flags & (EPOLLIN | EPOLLRDHUP)) {
				ready |= WUMP_IO_READ;
			}
			if (flags & EPOLLOUT) {
				ready |= WUMP_IO_WRITE;
			}
			if (flags & (EPOLLERR | EPOLLHUP)) {
				ready |= WUMP_IO_READ | WUMP_IO_WRITE;
			}
			io_waiter *reader = io->reader;
			io_waiter *writer = io->writer;
			if (reader != NULL && (reader->events & ready)) {
				complete(reader, reader->events & ready, 0);
			}
			if (writer != NULL && writer != reader && (writer->events & ready)) {
				complete(writer, writer->events & ready, 0);
			}
			if ((io->reader != NULL || io->writer != NULL) && arm(io) != 0) {
				fail_waiters(io, wump_errno());
			}
		}
		pthread_mutex_unlock(&p->mu);
	}
}

wump_poller *wump_poller_create(wump_runtime *rt) {
	wump_poller *p = calloc(1, sizeof(*p));
	if (p == NULL) {
		return NULL;
	}
	p->rt = rt;
	p->epfd = p->wakefd = -1;
	p->free_slot = SIZE_MAX;
	int error = pthread_mutex_init(&p->mu, NULL);
	if (error != 0) {
		free(p);
		wump_set_errno(error);
		return NULL;
	}
	p->epfd = epoll_create1(EPOLL_CLOEXEC);
	if (p->epfd < 0) {
		goto fail;
	}
	p->wakefd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	if (p->wakefd < 0) {
		goto fail;
	}
	struct epoll_event event = { .events = EPOLLIN, .data.u64 = 0 };
	if (epoll_ctl(p->epfd, EPOLL_CTL_ADD, p->wakefd, &event) != 0) {
		goto fail;
	}
	error = pthread_create(&p->thread, NULL, poller_entry, p);
	if (error != 0) {
		wump_set_errno(error);
		goto fail;
	}
	return p;
fail:
	error = wump_errno();
	if (p->wakefd >= 0) {
		close(p->wakefd);
	}
	if (p->epfd >= 0) {
		close(p->epfd);
	}
	pthread_mutex_destroy(&p->mu);
	free(p);
	wump_set_errno(error);
	return NULL;
}

void wump_poller_stop(wump_poller *p) {
	if (p == NULL) {
		return;
	}
	pthread_mutex_lock(&p->mu);
	p->stopping = 1;
	pthread_mutex_unlock(&p->mu);
	uint64_t value = 1;
	ssize_t result;
	do {
		result = write(p->wakefd, &value, sizeof(value));
	} while (result < 0 && wump_errno() == EINTR);
	if (result != (ssize_t)sizeof(value) && !(result < 0 && wump_errno() == EAGAIN)) {
		abort();
	}
	if (pthread_join(p->thread, NULL) != 0) {
		abort();
	}
}

void wump_poller_destroy(wump_poller *p) {
	if (p == NULL) {
		return;
	}
	for (size_t i = 0; i < p->cap; i++) {
		wump_io *io = p->slots[i].io;
		if (io != NULL) {
			if (io->fd >= 0) {
				close(io->fd);
			}
			free(io);
		}
	}
	close(p->wakefd);
	close(p->epfd);
	free(p->slots);
	pthread_mutex_destroy(&p->mu);
	free(p);
}

static int reserve_slot(wump_poller *p, wump_io *io) {
	if (p->free_slot == SIZE_MAX) {
		size_t cap = p->cap == 0 ? 16 : p->cap * 2;
		if (cap > UINT32_MAX) {
			cap = UINT32_MAX;
		}
		if (cap <= p->cap || cap > SIZE_MAX / sizeof(*p->slots)) {
			wump_set_errno(ENOMEM);
			return -1;
		}
		io_slot *slots = realloc(p->slots, cap * sizeof(*slots));
		if (slots == NULL) {
			return -1;
		}
		p->slots = slots;
		for (size_t i = p->cap; i < cap; i++) {
			p->slots[i] = (io_slot){ .next = i + 1 < cap ? i + 1 : SIZE_MAX };
		}
		p->free_slot = p->cap;
		p->cap = cap;
	}
	io->slot = p->free_slot;
	io_slot *slot = &p->slots[io->slot];
	p->free_slot = slot->next;
	slot->generation++;
	io->token = (uint64_t)slot->generation << 32 | io->slot;
	return 0;
}

static void release_slot(wump_io *io) {
	wump_poller *p = io->poller;
	io_slot *slot = &p->slots[io->slot];
	slot->io = NULL;
	/* Retire a slot permanently rather than wrapping its generation. */
	if (slot->generation != UINT32_MAX) {
		slot->next = p->free_slot;
		p->free_slot = io->slot;
	}
}

wump_io *wump_io_open(int fd) {
	if (wump_self() == NULL) {
		wump_set_errno(EINVAL);
		return NULL;
	}
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) {
		return NULL;
	}
	int fdflags = fcntl(fd, F_GETFD, 0);
	if (fdflags < 0) {
		return NULL;
	}
	wump_poller *p = wump_netpoll();
	if (p == NULL) {
		return NULL;
	}
	wump_io *io = calloc(1, sizeof(*io));
	if (io == NULL) {
		return NULL;
	}
	io->poller = p;
	io->fd = fd;
	pthread_mutex_lock(&p->mu);
	if (p->error != 0) {
		wump_set_errno(p->error);
		goto fail_object;
	}
	if (reserve_slot(p, io) != 0) {
		goto fail_object;
	}
	if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 ||
		fcntl(fd, F_SETFD, fdflags | FD_CLOEXEC) != 0) {
		goto fail_slot;
	}
	struct epoll_event event = {
		.events = EPOLLET | EPOLLONESHOT,
		.data.u64 = io->token
	};
	if (epoll_ctl(p->epfd, EPOLL_CTL_ADD, fd, &event) != 0) {
		goto fail_slot;
	}
	p->slots[io->slot].io = io;
	pthread_mutex_unlock(&p->mu);
	return io;
fail_slot: {
	int error = wump_errno();
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, fdflags);
	release_slot(io);
	wump_set_errno(error);
}
fail_object: {
	int error = wump_errno();
	pthread_mutex_unlock(&p->mu);
	free(io);
	wump_set_errno(error);
	return NULL;
}
}

static wump_poller *lock_io(wump_io *io, int require_open) {
	wump_runtime *rt = wump_current_runtime();
	if (wump_self() == NULL || io == NULL) {
		wump_set_errno(EINVAL);
		return NULL;
	}
	wump_poller *p = io->poller;
	if (p->rt != rt) {
		wump_set_errno(EXDEV);
		return NULL;
	}
	pthread_mutex_lock(&p->mu);
	int error = io->fd < 0 ? EBADF : p->error;
	if (require_open && error != 0) {
		pthread_mutex_unlock(&p->mu);
		wump_set_errno(error);
		return NULL;
	}
	return p;
}

static int close_locked(wump_io *io) {
	int error = 0;
	if (epoll_ctl(io->poller->epfd, EPOLL_CTL_DEL, io->fd, NULL) != 0 && wump_errno() != ENOENT) {
		error = wump_errno();
	}
	if (close(io->fd) != 0) {
		error = wump_errno();
	}
	io->fd = -1;
	fail_waiters(io, EBADF);
	return error;
}

int wump_io_fd(wump_io *io) {
	wump_poller *p = lock_io(io, 1);
	if (p == NULL) {
		return -1;
	}
	int fd = io->fd;
	pthread_mutex_unlock(&p->mu);
	return fd;
}

int wump_io_close(wump_io *io) {
	wump_poller *p = lock_io(io, 0);
	if (p == NULL) {
		return -1;
	}
	int error = io->fd < 0 ? EBADF : close_locked(io);
	pthread_mutex_unlock(&p->mu);
	if (error != 0) {
		wump_set_errno(error);
		return -1;
	}
	return 0;
}

int wump_io_free(wump_io *io) {
	if (io == NULL) {
		return 0;
	}
	wump_poller *p = lock_io(io, 0);
	if (p == NULL) {
		return -1;
	}
	if (io->active != 0) {
		pthread_mutex_unlock(&p->mu);
		wump_set_errno(EBUSY);
		return -1;
	}
	int error = io->fd < 0 ? 0 : close_locked(io);
	release_slot(io);
	pthread_mutex_unlock(&p->mu);
	free(io);
	if (error != 0) {
		wump_set_errno(error);
		return -1;
	}
	return 0;
}

static int make_deadline(int64_t timeout, int64_t *deadline) {
	if (timeout < -1) {
		wump_set_errno(EINVAL);
		return -1;
	}
	if (timeout <= 0) {
		*deadline = timeout;
		return 0;
	}
	int64_t now = wump_now();
	if (timeout > INT64_MAX - now) {
		wump_set_errno(EOVERFLOW);
		return -1;
	}
	*deadline = now + timeout;
	return 0;
}

static int poll_ready(wump_io *io, int events) {
	struct pollfd fd = { .fd = io->fd };
	if (events & WUMP_IO_READ) {
		fd.events |= POLLIN | POLLRDHUP;
	}
	if (events & WUMP_IO_WRITE) {
		fd.events |= POLLOUT;
	}
	int n;
	do {
		n = poll(&fd, 1, 0);
	} while (n < 0 && wump_errno() == EINTR);
	if (n < 0) {
		return -1;
	}
	if (fd.revents & POLLNVAL) {
		wump_set_errno(EBADF);
		return -1;
	}
	int ready = 0;
	if (fd.revents & (POLLIN | POLLRDHUP)) {
		ready |= WUMP_IO_READ;
	}
	if (fd.revents & POLLOUT) {
		ready |= WUMP_IO_WRITE;
	}
	if (fd.revents & (POLLERR | POLLHUP)) {
		ready |= WUMP_IO_READ | WUMP_IO_WRITE;
	}
	return ready & events;
}

static void detach_io(void *arg) {
	io_waiter *w = arg;
	wump_io *io = w->io;
	wump_poller *p = io->poller;
	pthread_mutex_lock(&p->mu);
	wump_timer_cancel(&w->timer);
	if (w->registered) {
		unlink_wait(w);
		wump_io_count(p->rt, -1, NULL);
		if (io->fd >= 0 && (io->reader != NULL || io->writer != NULL) && arm(io) != 0) {
			fail_waiters(io, wump_errno());
		}
	}
	io->active--;
	w->g->cancel_fn = NULL;
	w->g->cancel_arg = NULL;
	pthread_mutex_unlock(&p->mu);
}

static void park_io(void *arg) {
	io_waiter *w = arg;
	wump_poller *p = w->io->poller;
#ifdef WUMP_TSAN
	__tsan_mutex_pre_lock(&p->mu, 0);
	__tsan_mutex_post_lock(&p->mu, 0, 0);
#endif
	if (w->timer.deadline > 0 && wump_timer_add(&w->timer) != 0) {
		complete(w, 0, wump_errno());
	}
	pthread_mutex_unlock(&p->mu);
}

static int wait_until(wump_io *io, int events, int64_t deadline) {
	wump_poller *p = lock_io(io, 1);
	if (p == NULL) {
		return -1;
	}
	if (((events & WUMP_IO_READ) && io->reader != NULL) ||
		((events & WUMP_IO_WRITE) && io->writer != NULL)) {
		pthread_mutex_unlock(&p->mu);
		wump_set_errno(EBUSY);
		return -1;
	}
	int ready = poll_ready(io, events);
	if (ready != 0 || (deadline >= 0 && (deadline == 0 || wump_now() >= deadline))) {
		pthread_mutex_unlock(&p->mu);
		return ready;
	}
	io_waiter w = { .io = io, .g = wump_self(), .events = events, .registered = 1,
		.timer = { .deadline = deadline, .index = SIZE_MAX } };
	atomic_init(&w.winner, WUMP_SEL_PENDING);
	w.timer.g = w.g;
	w.timer.winner = &w.winner;
	if (events & WUMP_IO_READ) {
		io->reader = &w;
	}
	if (events & WUMP_IO_WRITE) {
		io->writer = &w;
	}
	wump_io_count(p->rt, 1, NULL);
	if (arm(io) != 0) {
		int error = wump_errno();
		unlink_wait(&w);
		wump_io_count(p->rt, -1, NULL);
		fail_waiters(io, error);
		pthread_mutex_unlock(&p->mu);
		wump_set_errno(error);
		return -1;
	}
	io->active++;
	w.g->cancel_fn = detach_io;
	w.g->cancel_arg = &w;
#ifdef WUMP_TSAN
	__tsan_mutex_pre_unlock(&p->mu, 0);
	__tsan_mutex_post_unlock(&p->mu, 0);
#endif
	wump_park(park_io, &w);
	detach_io(&w);
	size_t winner = atomic_load(&w.winner);
	if (winner == WUMP_SEL_ERROR) {
		wump_set_errno(w.error);
		return -1;
	}
	return winner == WUMP_SEL_TIMEOUT ? 0 : w.ready;
}

int wump_io_wait(wump_io *io, int events, int64_t timeout_ns) {
	if (events == 0 || (events & ~(WUMP_IO_READ | WUMP_IO_WRITE))) {
		wump_set_errno(EINVAL);
		return -1;
	}
	int64_t deadline;
	if (make_deadline(timeout_ns, &deadline) != 0) {
		return -1;
	}
	return wait_until(io, events, deadline);
}

static int acquire(wump_io *io) {
	wump_poller *p = lock_io(io, 1);
	if (p == NULL) {
		return -1;
	}
	io->active++;
	pthread_mutex_unlock(&p->mu);
	return 0;
}

static void release(wump_io *io) {
	wump_poller *p = io->poller;
	pthread_mutex_lock(&p->mu);
	io->active--;
	pthread_mutex_unlock(&p->mu);
}

static int await(wump_io *io, int events, int64_t deadline) {
	/* Readiness can be stale or continuously writable while connect is
	 * still pending. Bound retries even when polling never parks. */
	if (deadline == 0 || (deadline > 0 && wump_now() >= deadline)) {
		wump_set_errno(ETIMEDOUT);
		return -1;
	}
	int ready = wait_until(io, events, deadline);
	if (ready == 0) {
		wump_set_errno(ETIMEDOUT);
		return -1;
	}
	return ready < 0 ? -1 : 0;
}

static ssize_t transfer(wump_io *io, void *buf, size_t size, int64_t timeout, int writing) {
	int64_t deadline;
	if ((size != 0 && buf == NULL) || size > SSIZE_MAX) {
		wump_set_errno(EINVAL);
		return -1;
	}
	if (make_deadline(timeout, &deadline) != 0 || acquire(io) != 0) {
		return -1;
	}
	wump_poller *p = io->poller;
	ssize_t result;
	int error;
	for (;;) {
		pthread_mutex_lock(&p->mu);
		if (io->fd < 0) {
			result = -1;
			wump_set_errno(EBADF);
		} else {
			result = writing ? write(io->fd, buf, size) : read(io->fd, buf, size);
		}
		error = wump_errno();
		pthread_mutex_unlock(&p->mu);
		if (result >= 0 || (error != EINTR && error != EAGAIN && error != EWOULDBLOCK)) {
			break;
		}
		if (error == EINTR) {
			if (deadline > 0 && wump_now() >= deadline) {
				error = ETIMEDOUT;
				break;
			}
			continue;
		}
		if (await(io, writing ? WUMP_IO_WRITE : WUMP_IO_READ, deadline) != 0) {
			error = wump_errno();
			break;
		}
	}
	release(io);
	if (result < 0) {
		wump_set_errno(error);
	}
	return result;
}

ssize_t wump_io_read(wump_io *io, void *buf, size_t size, int64_t timeout_ns) {
	return transfer(io, buf, size, timeout_ns, 0);
}

ssize_t wump_io_write(wump_io *io, const void *buf, size_t size, int64_t timeout_ns) {
	return transfer(io, (void *)buf, size, timeout_ns, 1);
}

wump_io *wump_io_accept(wump_io *io, struct sockaddr *addr, socklen_t *len, int64_t timeout_ns) {
	int64_t deadline;
	if (addr != NULL && len == NULL) {
		wump_set_errno(EINVAL);
		return NULL;
	}
	if (make_deadline(timeout_ns, &deadline) != 0 || acquire(io) != 0) {
		return NULL;
	}
	wump_poller *p = io->poller;
	int fd, error;
	for (;;) {
		pthread_mutex_lock(&p->mu);
		if (io->fd < 0) {
			fd = -1;
			wump_set_errno(EBADF);
		} else {
			fd = accept4(io->fd, addr, len, SOCK_NONBLOCK | SOCK_CLOEXEC);
		}
		error = wump_errno();
		pthread_mutex_unlock(&p->mu);
		if (fd >= 0 || (error != EINTR && error != EAGAIN && error != EWOULDBLOCK)) {
			break;
		}
		if (error == EINTR) {
			if (deadline > 0 && wump_now() >= deadline) {
				error = ETIMEDOUT;
				break;
			}
			continue;
		}
		if (await(io, WUMP_IO_READ, deadline) != 0) {
			error = wump_errno();
			break;
		}
	}
	release(io);
	if (fd < 0) {
		wump_set_errno(error);
		return NULL;
	}
	wump_io *accepted = wump_io_open(fd);
	if (accepted == NULL) {
		error = wump_errno();
		close(fd);
		wump_set_errno(error);
	}
	return accepted;
}

int wump_io_connect(wump_io *io, const struct sockaddr *addr, socklen_t len, int64_t timeout_ns) {
	int64_t deadline;
	if (addr == NULL) {
		wump_set_errno(EINVAL);
		return -1;
	}
	if (make_deadline(timeout_ns, &deadline) != 0 || acquire(io) != 0) {
		return -1;
	}
	wump_poller *p = io->poller;
	pthread_mutex_lock(&p->mu);
	int result;
	if (io->fd < 0) {
		result = -1;
		wump_set_errno(EBADF);
	} else {
		result = connect(io->fd, addr, len);
	}
	int error = result == 0 ? 0 : wump_errno();
	pthread_mutex_unlock(&p->mu);
	while (error == EINPROGRESS || error == EALREADY || error == EINTR) {
		if (await(io, WUMP_IO_WRITE, deadline) != 0) {
			error = wump_errno();
			break;
		}
		pthread_mutex_lock(&p->mu);
		socklen_t size = sizeof(error);
		if (io->fd < 0) {
			error = EBADF;
		} else if (getsockopt(io->fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0) {
			error = wump_errno();
		} else if (error == 0) {
			/* A stale readiness notification can precede completion. */
			struct sockaddr_storage peer;
			socklen_t peer_len = sizeof(peer);
			if (getpeername(io->fd, (struct sockaddr *)&peer, &peer_len) != 0) {
				error = wump_errno() == ENOTCONN ? EINPROGRESS : wump_errno();
			}
		}
		pthread_mutex_unlock(&p->mu);
	}
	release(io);
	if (error != 0) {
		wump_set_errno(error);
		return -1;
	}
	return 0;
}
