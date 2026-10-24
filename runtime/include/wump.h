/* wump — M:N coroutine runtime with Go-style channels. */
#ifndef WUMP_H
#define WUMP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*wump_fn)(void *arg);

/* Start the runtime with `nprocs` worker threads (0 = number of CPUs),
 * run `main_fn(arg)` as a coroutine, and return once it returns.
 * The calling thread becomes worker 0. Coroutines still alive when
 * main_fn returns are abandoned, as in Go. Returns 0, or -1 on error. */
int wump_run(wump_fn main_fn, void *arg, int nprocs);

/* Spawn a coroutine. Callable only from inside the runtime. */
int wump_go(wump_fn fn, void *arg);

/* Let other runnable coroutines run. */
void wump_yield(void);

/* Number of worker threads. Index of the worker running the caller. */
int wump_nprocs(void);
int wump_worker_id(void);

/* Channels. Elements are fixed-size and copied by value.
 * cap == 0 makes an unbuffered (rendezvous) channel. */
typedef struct wump_chan wump_chan;

wump_chan *wump_chan_make(size_t elem_size, size_t cap);
/* Free a channel. Nobody may be using it. */
void wump_chan_free(wump_chan *ch);

/* 0 on success, -1 if the channel is closed (Go panics; we report). */
int wump_chan_send(wump_chan *ch, const void *elem);
/* 1 if a value was received, 0 if the channel is closed and drained
 * (`out` is zeroed). */
int wump_chan_recv(wump_chan *ch, void *out);
/* -1 if already closed. Wakes every blocked sender and receiver. */
int wump_chan_close(wump_chan *ch);

size_t wump_chan_len(wump_chan *ch);
size_t wump_chan_cap(wump_chan *ch);

#ifdef __cplusplus
}
#endif

#endif
