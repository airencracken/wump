/* wump — M:N coroutine runtime with Go-style channels. */
#ifndef WUMP_H
#define WUMP_H

#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*wump_fn)(void *arg);

/* Start the runtime with `nprocs` execution slots (0 = number of CPUs),
 * initially one OS thread per slot, and run main_fn(arg) as a coroutine.
 * The calling thread initially owns slot 0. Coroutines still alive when
 * main_fn returns are abandoned, as in Go. Shutdown is cooperative: each
 * running task must return, yield, or park in a channel/selection/sleep/I/O.
 * Outstanding entered native calls must return before cleanup completes.
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

/* Poll at a safe boundary in compute-bound code. Yields after roughly
 * 10 ms of execution since this dispatch's first poll, or on shutdown.
 * Returns 1 after yielding, otherwise 0; preserves task-local errno.
 * A no-op outside a task or inside a marked native call. Like yield,
 * this can migrate the task. It cannot interrupt code that never polls. */
int wump_checkpoint(void);

/* Number of execution slots (0 outside a runtime).
 * Current slot index (-1 outside a runtime or during a native call).
 * A slot can move between OS threads after syscall handoff. */
int wump_nprocs(void);
int wump_worker_id(void);

/* Bracket a known blocking native call. Enter hands this task's execution
 * slot to another OS thread; the native call continues on the same thread
 * and stack. Exit reschedules the task, possibly on another thread/slot.
 * Both return 0 on success, preserving errno; failures return -1 with
 * errno set. Failed enter retains the slot: do not block after failure.
 * Enter may fail on replacement-thread setup, EBUSY for nesting, or
 * ECANCELED during shutdown. Invalid context/unmatched exit is EINVAL.
 * Between enter/exit, worker_id is -1. Calls requiring a running task
 * (spawn/send/recv/selection/sleep/I/O) are invalid; yield is a no-op.
 * Outside-runtime-safe allocation/free and metadata queries remain valid.
 * Release native thread-owned locks before exit. Returning from a task
 * without exit terminates the runtime with EPROTO. Shutdown waits for
 * outstanding native calls to return; they cannot be forcibly canceled. */
int wump_syscall_enter(void);
int wump_syscall_exit(void);

/* Bracket a normally returning native callback. The callback runs on the
 * caller's OS thread/stack and can report results through arg and errno.
 * It must not invoke scheduling APIs, exit/enter markers, pthread_exit,
 * or longjmp out of the callback. Returns 0 or -1; setup failure does not
 * invoke fn. NULL fn is EINVAL. */
int wump_blocking(wump_fn fn, void *arg);

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

/* Nonblocking sockets/pipes, owned by the current runtime. Open takes
 * ownership of fd only on success, setting O_NONBLOCK and FD_CLOEXEC.
 * Do not close/reuse the native fd or attach it elsewhere while owned.
 * Regular files are unsupported (epoll reports EPERM). */
typedef struct wump_io wump_io;
wump_io *wump_io_open(int fd);
/* Borrow the native fd for inspection/configuration. The caller must keep
 * the handle open while using it; never close the borrowed descriptor. */
int wump_io_fd(wump_io *io);
/* Close interrupts parked operations with EBADF, leaving the handle alive.
 * Free also closes, but fails with EBUSY while any operation is in flight.
 * No new calls may begin concurrently with free. Free(NULL) is harmless.
 * Shutdown closes and frees all remaining handles after detaching waiters;
 * handle pointers become invalid when their runtime returns. */
int wump_io_close(wump_io *io);
int wump_io_free(wump_io *io);

enum { WUMP_IO_READ = 1, WUMP_IO_WRITE = 2 };
/* Return ready bits, 0 on timeout, or -1 with errno set. Readiness is a
 * snapshot: callers must handle EAGAIN when performing native I/O.
 * timeout_ns follows sel: -1 indefinite, 0 poll, positive monotonic wait.
 * At most one parked waiter per direction; conflicts return EBUSY.
 * Handles may only be used from tasks in the runtime that opened them. */
int wump_io_wait(wump_io *io, int events, int64_t timeout_ns);

/* Timed equivalents of read/write/accept/connect. They retry EINTR and
 * park on EAGAIN without blocking a worker. Reads/writes return partial
 * results like POSIX; write retains write(2)'s SIGPIPE behavior. An expired
 * wait (including zero timeout on would-block) reports ETIMEDOUT.
 * Accept returns an owned, nonblocking, close-on-exec handle. A connect
 * timeout leaves the underlying connection attempt pending; close the
 * handle to abandon it. Ordinary syscall errors propagate through errno. */
ssize_t wump_io_read(wump_io *io, void *buf, size_t size, int64_t timeout_ns);
ssize_t wump_io_write(wump_io *io, const void *buf, size_t size, int64_t timeout_ns);
wump_io *wump_io_accept(wump_io *io, struct sockaddr *addr, socklen_t *len, int64_t timeout_ns);
int wump_io_connect(wump_io *io, const struct sockaddr *addr, socklen_t len, int64_t timeout_ns);

#ifdef __cplusplus
}
#endif

#endif
