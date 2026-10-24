#ifndef WUMP_INTERNAL_H
#define WUMP_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

#include "wump.h"

#define WUMP_CACHELINE 64
#define WUMP_LOCALQ 256            /* per-worker run queue capacity */
#define WUMP_STACK_CANARY 0x77756d702d737461ULL  /* "wump-sta" */

#if defined(__SANITIZE_THREAD__)
#define WUMP_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define WUMP_TSAN 1
#endif
#endif

enum wump_gstate { G_RUNNABLE, G_RUNNING, G_WAITING, G_DEAD };

/* A coroutine. Lives at the top of its own stack mapping. */
typedef struct wump_g {
    void *sp;                   /* saved stack pointer while switched out */
    wump_fn fn;
    void *arg;
    int state;
    uint64_t id;
    struct wump_g *next;        /* global run queue / free lists */
    void *map;                  /* whole mapping, guard page included */
    size_t map_len;
    uint64_t *stack_lo;         /* lowest usable address; holds the canary */
#ifdef WUMP_TSAN
    void *tsan_fiber;
#endif
} wump_g;

typedef struct wump_worker {
    int id;
    pthread_t thread;
    void *sched_sp;             /* the worker's scheduler context */
    wump_g *cur;
    wump_g *runnext;            /* owner-only; never stolen */
    uint32_t runnext_streak;
    uint32_t tick;
    int spinning;
    uint64_t rng;

    /* Hook run on the scheduler stack right after a coroutine parks. */
    void (*park_fn)(void *);
    void *park_arg;

    wump_g *gcache;             /* free coroutines (stack + struct) */
    int ngcache;

#ifdef WUMP_TSAN
    void *tsan_sched_fiber;
#endif

    /* Local run queue; stealers take the lock. */
    _Alignas(WUMP_CACHELINE) pthread_mutex_t q_mu;
    uint32_t qhead, qtail;      /* under q_mu; tail - head = length */
    _Atomic uint32_t qlen;      /* lock-free peek for idle checks */
    wump_g *q[WUMP_LOCALQ];
} wump_worker;

/* ctx_x86_64.S */
void wump_ctx_switch(void **save_sp, void *load_sp);
void wump_ctx_trampoline(void);
void *wump_ctx_init(void *stack_top, void (*fn)(void *), void *arg);

/* stack.c */
wump_g *wump_stack_new(size_t stack_size);
void wump_stack_free(wump_g *g);

/* sched.c, for channels and future primitives */
wump_g *wump_self(void);
/* Park the running coroutine. `unlock(arg)` runs on the scheduler stack
 * once the coroutine's context is saved; the waker must not be able to
 * find this coroutine until then. */
void wump_park(void (*unlock)(void *), void *arg);
/* Make a parked coroutine runnable. */
void wump_ready(wump_g *g);

#endif
