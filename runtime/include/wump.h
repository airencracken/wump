/* wump — M:N coroutine runtime with Go-style channels. */
#ifndef WUMP_H
#define WUMP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*wump_fn)(void *arg);

/* Start the runtime with `nprocs` worker threads (0 = number of CPUs),
 * run `main_fn(arg)` as a coroutine, and return once it returns.
 * The calling thread becomes worker 0. Coroutines still alive when
 * main_fn returns are abandoned, as in Go. Shutdown is cooperative: each
 * running task must return, yield, or park in a channel/selection/sleep.
 * Returns 0, or -1 with errno set (including EDEADLK when all tasks park).
 * Nested runs on a worker fail with EBUSY; independent callers may run
 * separate runtimes, but must not share channels between active runtimes. */
int wump_run(wump_fn main_fn, void *arg, int nprocs);

/* Spawn a coroutine. Callable only from inside the runtime. */
int wump_go(wump_fn fn, void *arg);

/* Let other runnable coroutines run. Tasks may migrate between workers.
 * Do not retain native thread-local addresses or hold native thread-owned
 * mutexes across scheduling points. A no-op outside a runtime. */
void wump_yield(void);

/* Number of worker threads (0 outside a runtime).
 * Index of the worker running the caller (-1 outside a runtime). */
int wump_nprocs(void);
int wump_worker_id(void);

/* Channels. Elements are fixed-size and copied by value.
 * cap == 0 makes an unbuffered (rendezvous) channel.
 * elem_size == 0 supports synchronization without a payload; in that
 * case send/recv accept NULL. Allocation may happen outside the runtime.
 * Values are byte copies: ownership of referenced storage is the caller's. */
typedef struct wump_chan wump_chan;

wump_chan *wump_chan_make(size_t elem_size, size_t cap);
/* Free a channel (NULL is harmless). No new operations or parked waiters
 * may exist. Completed rendezvous/close operations synchronize with free,
 * including the waker's final unlock. The runtime never owns channels. */
void wump_chan_free(wump_chan *ch);

/* send/recv/close require a running task and a non-NULL channel.
 * 0 on successful send, -1 on error (EPIPE if closed; EINVAL for invalid
 * arguments or calls outside a runtime). */
int wump_chan_send(wump_chan *ch, const void *elem);
/* 1 if a value was received, 0 if the channel is closed and drained
 * (`out` is zeroed), or -1 with EINVAL for invalid use. */
int wump_chan_recv(wump_chan *ch, void *out);
/* Close returns 0, or -1 on error (EPIPE if already closed).
 * Wakes every blocked sender and receiver; buffered values remain. */
int wump_chan_close(wump_chan *ch);

size_t wump_chan_len(wump_chan *ch);
size_t wump_chan_cap(wump_chan *ch);

enum wump_case_op { WUMP_RECV, WUMP_SEND };
typedef struct wump_case {
	wump_chan *ch;             /* NULL disables this case */
	enum wump_case_op op;
	void *data;                /* send source or receive destination */
	int result;                /* selected channel operation's return value */
} wump_case;

/* Select exactly one ready channel operation, polling in randomized order.
 * timeout_ns: -1 waits indefinitely, 0 is a nonblocking/default selection,
 * positive values bound the wait using monotonic time, in nanoseconds.
 * Returns 1 for a selected case, 0 for timeout/default, or -1 on error.
 * On success *chosen is the original case index; on timeout it is SIZE_MAX.
 * chosen may be NULL. Only the selected case's result/data are modified.
 * A selected send on a closed channel returns 1 with case.result == -1
 * and errno == EPIPE. Invalid input/allocation errors leave outputs alone.
 * cases may be NULL only when ncases == 0. Duplicate channels are allowed.
 * Every referenced channel and data buffer must stay alive until this
 * call returns; shutdown detaches all abandoned selections and timers. */
int wump_sel(wump_case *cases, size_t ncases, int64_t timeout_ns, size_t *chosen);

/* Park this task for at least duration_ns of monotonic time. Zero yields;
 * negative durations are invalid. Returns 0 or -1 with errno set. */
int wump_sleep(int64_t duration_ns);

#ifdef __cplusplus
}
#endif

#endif
