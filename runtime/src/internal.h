#ifndef WUMP_INTERNAL_H
#define WUMP_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

#include "wump.h"

#define WUMP_CACHELINE 64
#define WUMP_LOCALQ 256
#define WUMP_STACK_SIZE (256 * 1024)
#define WUMP_MAIN_STACK_SIZE (1024 * 1024)
#define WUMP_STACK_CACHE 32
#define WUMP_STACK_CANARY UINT64_C(0x77756d702d737461)

#if defined(__SANITIZE_THREAD__)
#define WUMP_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define WUMP_TSAN 1
#endif
#endif
#ifdef WUMP_TSAN
#include <sanitizer/tsan_interface.h>
#endif
#ifdef WUMP_VALGRIND
#include <valgrind/valgrind.h>
#endif

enum wump_gstate { G_RUNNABLE, G_RUNNING, G_WAITING, G_DEAD, G_SYSCALL };

/* A coroutine lives at the top of its stack mapping. Queue/cache links
 * and the runtime's mapping registry must remain independent. */
typedef struct wump_g {
	void *sp;
	wump_fn fn;
	void *arg;
	enum wump_gstate state;
	int saved_errno;
	struct wump_g *next;
	struct wump_g *all_next, *all_prev;
	void *map;
	size_t map_len;
	uint64_t *stack_lo;
	void (*cancel_fn)(void *);
	void *cancel_arg;
#ifdef WUMP_VALGRIND
	unsigned valgrind_stack;
#endif
#ifdef WUMP_TSAN
	void *tsan_fiber;
#endif
} wump_g;

typedef struct wump_runtime wump_runtime;
typedef struct wump_poller wump_poller;

#define WUMP_SEL_PENDING SIZE_MAX
#define WUMP_SEL_TIMEOUT (SIZE_MAX - 1)
#define WUMP_SEL_ERROR (SIZE_MAX - 2)

/* Stack-resident timer. The runtime mutex protects heap membership;
 * expiry claims the same winner word as channel waiters. */
typedef struct wump_timer {
	wump_runtime *rt;
	wump_g *g;
	_Atomic size_t *winner;
	int64_t deadline;
	size_t index;
} wump_timer;

/* P: one M owns the slot and its caches; other Ms may steal under q_mu. */
typedef struct wump_worker {
	wump_runtime *rt;
	int id;
	unsigned tick;
	unsigned steal_start;
	uint64_t rng;
	wump_g *gcache;
	int ngcache;
	_Alignas(WUMP_CACHELINE) pthread_mutex_t q_mu;
	unsigned qhead, qtail;
	wump_g *q[WUMP_LOCALQ];
} wump_worker;

void wump_ctx_switch(void **save_sp, void *load_sp);
void wump_ctx_trampoline(void);
void *wump_ctx_init(void *stack_top, void (*fn)(void *), void *arg);
wump_g *wump_stack_new(size_t stack_size);
void wump_stack_free(wump_g *g);

wump_g *wump_self(void);
/* Called with the primitive's lock held. The scheduler releases it only
 * after saving the coroutine context and finishing all access to it. */
void wump_park(void (*unlock)(void *), void *arg);
void wump_ready(wump_g *g);
uint64_t wump_random(void);
int64_t wump_now(void);
/* Add only on the scheduler stack, after the parked context is saved. */
int wump_timer_add(wump_timer *timer);
void wump_timer_cancel(wump_timer *timer);

wump_runtime *wump_current_runtime(void);
wump_poller *wump_netpoll(void);
/* Publish external wakeups and change the active-I/O count atomically
 * under the scheduler mutex, preventing a false idle deadlock. */
void wump_io_count(wump_runtime *rt, int delta, wump_g *ready);
wump_poller *wump_poller_create(wump_runtime *rt);
void wump_poller_stop(wump_poller *poller);
void wump_poller_destroy(wump_poller *poller);
/* Access libc errno without letting a caller cache its native TLS address
 * across a coroutine migration. These accessors must never be inlined. */
int wump_errno(void);
void wump_set_errno(int error);

#endif
