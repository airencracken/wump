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

enum wump_gstate { G_RUNNABLE, G_RUNNING, G_WAITING, G_DEAD };

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
typedef struct wump_worker {
	wump_runtime *rt;
	int id;
	pthread_t thread;
	void *sched_sp;
	wump_g *cur;
	unsigned tick;
	unsigned steal_start;
	void (*park_fn)(void *);
	void *park_arg;
	wump_g *gcache;
	int ngcache;
#ifdef WUMP_TSAN
	void *tsan_sched_fiber;
#endif
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

#endif
