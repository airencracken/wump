#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "internal.h"

/* M owns an OS thread/context; P (wump_worker) owns queues and caches.
 * A blocking M keeps its coroutine stack but hands its P to another M. */
typedef struct wump_machine {
	wump_runtime *rt;
	wump_worker *p;
	pthread_t thread;
	pthread_cond_t wake;
	struct wump_machine *next, *spare_next;
	void *sched_sp;
	wump_g *cur;
	int in_syscall;
	void (*park_fn)(void *);
	void *park_arg;
#ifdef WUMP_TSAN
	void *tsan_sched_fiber;
#endif
#ifdef WUMP_ASAN
	void *asan_fake_stack;
	const void *asan_stack_bottom;
	size_t asan_stack_size;
#endif
} wump_machine;

struct wump_runtime {
	pthread_mutex_t mu;
	pthread_cond_t work;
	wump_worker *workers;
	int nprocs;
	int started;
	int idle;
	int error;
	_Atomic int stopping;
	uint64_t epoch;
	wump_g *head, *tail;
	wump_g *all;
	wump_g *main_g;
	wump_timer **timers;
	size_t ntimers, timer_cap;
	wump_poller *poller;
	size_t io_waiters;
	size_t syscalls;
	wump_machine *machines, *spare;
};

static _Thread_local wump_machine *current;

static __attribute__((noinline)) wump_machine *current_machine(void) {
	/* A task can resume on another M. Never cache a native TLS address
	 * or its value across a context switch in a calling function. */
	__asm__ volatile("" ::: "memory");
	return current;
}

static void notify(wump_runtime *rt) {
	pthread_mutex_lock(&rt->mu);
	rt->epoch++;
	pthread_cond_signal(&rt->work);
	pthread_mutex_unlock(&rt->mu);
}

static void stop_locked(wump_runtime *rt, int error) {
	if (!atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
		rt->error = error;
		atomic_store_explicit(&rt->stopping, 1, memory_order_release);
	} else if (rt->error == 0 && error != 0) {
		/* A native call can reveal a protocol error while shutdown is
		 * waiting for it. Preserve that error in the final run result. */
		rt->error = error;
	}
	pthread_cond_broadcast(&rt->work);
	for (wump_machine *m = rt->machines; m != NULL; m = m->next) {
		pthread_cond_signal(&m->wake);
	}
}

static void stop(wump_runtime *rt, int error) {
	pthread_mutex_lock(&rt->mu);
	stop_locked(rt, error);
	pthread_mutex_unlock(&rt->mu);
}

void wump_halt(int error) {
	wump_machine *m = current_machine();
	if (m != NULL) {
		stop(m->rt, error);
	}
}

static void global_push_locked(wump_runtime *rt, wump_g *g) {
	g->next = NULL;
	if (rt->tail != NULL) {
		rt->tail->next = g;
	} else {
		rt->head = g;
	}
	rt->tail = g;
	rt->epoch++;
	pthread_cond_signal(&rt->work);
}

static void global_push(wump_runtime *rt, wump_g *g) {
	pthread_mutex_lock(&rt->mu);
	global_push_locked(rt, g);
	pthread_mutex_unlock(&rt->mu);
}

wump_runtime *wump_current_runtime(void) {
	wump_machine *m = current_machine();
	return m != NULL ? m->rt : NULL;
}

wump_poller *wump_netpoll(void) {
	wump_runtime *rt = current_machine()->rt;
	pthread_mutex_lock(&rt->mu);
	if (rt->poller == NULL) {
		rt->poller = wump_poller_create(rt);
	}
	wump_poller *poller = rt->poller;
	pthread_mutex_unlock(&rt->mu);
	return poller;
}

void wump_io_count(wump_runtime *rt, int delta, wump_g *ready) {
	pthread_mutex_lock(&rt->mu);
	if (delta > 0) {
		rt->io_waiters++;
	} else {
		assert(rt->io_waiters != 0);
		rt->io_waiters--;
	}
	if (ready != NULL) {
		ready->state = G_RUNNABLE;
		global_push_locked(rt, ready);
	} else {
		rt->epoch++;
		pthread_cond_signal(&rt->work);
	}
	pthread_mutex_unlock(&rt->mu);
}

int64_t wump_now(void) {
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
		now.tv_sec > (INT64_MAX - now.tv_nsec) / INT64_C(1000000000)) {
		abort();
	}
	return (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
}

static void timer_swap(wump_runtime *rt, size_t a, size_t b) {
	wump_timer *tmp = rt->timers[a];
	rt->timers[a] = rt->timers[b];
	rt->timers[b] = tmp;
	rt->timers[a]->index = a;
	rt->timers[b]->index = b;
}

static void timer_up(wump_runtime *rt, size_t index) {
	while (index != 0) {
		size_t parent = (index - 1) / 2;
		if (rt->timers[parent]->deadline <= rt->timers[index]->deadline) {
			break;
		}
		timer_swap(rt, parent, index);
		index = parent;
	}
}

static void timer_remove(wump_runtime *rt, wump_timer *timer) {
	size_t index = timer->index;
	timer->index = SIZE_MAX;
	rt->ntimers--;
	if (index == rt->ntimers) {
		return;
	}
	rt->timers[index] = rt->timers[rt->ntimers];
	rt->timers[index]->index = index;
	if (index != 0 && rt->timers[index]->deadline < rt->timers[(index - 1) / 2]->deadline) {
		timer_up(rt, index);
		return;
	}
	while (index < rt->ntimers / 2) {
		size_t child = index * 2 + 1;
		if (child + 1 < rt->ntimers &&
			rt->timers[child + 1]->deadline < rt->timers[child]->deadline) {
			child++;
		}
		if (rt->timers[index]->deadline <= rt->timers[child]->deadline) {
			break;
		}
		timer_swap(rt, index, child);
		index = child;
	}
}

int wump_timer_add(wump_timer *timer) {
	wump_runtime *rt = current_machine()->rt;
	timer->rt = rt;
	pthread_mutex_lock(&rt->mu);
	if (rt->ntimers == rt->timer_cap) {
		size_t cap = rt->timer_cap == 0 ? 16 : rt->timer_cap * 2;
		if (cap < rt->timer_cap || cap > SIZE_MAX / sizeof(*rt->timers)) {
			pthread_mutex_unlock(&rt->mu);
			errno = ENOMEM;
			return -1;
		}
		wump_timer **timers = realloc(rt->timers, cap * sizeof(*timers));
		if (timers == NULL) {
			pthread_mutex_unlock(&rt->mu);
			return -1;
		}
		rt->timers = timers;
		rt->timer_cap = cap;
	}
	timer->index = rt->ntimers;
	rt->timers[rt->ntimers++] = timer;
	timer_up(rt, timer->index);
	rt->epoch++;
	pthread_cond_signal(&rt->work);
	pthread_mutex_unlock(&rt->mu);
	/* Expiry may already have resumed the task. Do not touch timer. */
	return 0;
}

void wump_timer_cancel(wump_timer *timer) {
	wump_runtime *rt = timer->rt;
	if (rt == NULL) {
		return;
	}
	pthread_mutex_lock(&rt->mu);
	if (timer->index != SIZE_MAX) {
		timer_remove(rt, timer);
		rt->epoch++;
		pthread_cond_signal(&rt->work);
	}
	pthread_mutex_unlock(&rt->mu);
}

static void timers_expire_locked(wump_runtime *rt) {
	if (rt->ntimers != 0) {
		int64_t now = wump_now();
		while (rt->ntimers != 0 && rt->timers[0]->deadline <= now) {
			wump_timer *timer = rt->timers[0];
			timer_remove(rt, timer);
			size_t expected = WUMP_SEL_PENDING;
			if (atomic_compare_exchange_strong(timer->winner, &expected, WUMP_SEL_TIMEOUT)) {
				wump_g *g = timer->g;
				g->state = G_RUNNABLE;
				global_push_locked(rt, g);
			}
			/* A published task may free its timer after we unlock mu. */
		}
	}
}

uint64_t wump_random(void) {
	wump_worker *p = current_machine()->p;
	uint64_t x = p->rng;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	p->rng = x;
	return x;
}

static wump_g *global_pop(wump_runtime *rt) {
	pthread_mutex_lock(&rt->mu);
	wump_g *g = rt->head;
	if (g != NULL) {
		rt->head = g->next;
		if (rt->head == NULL) {
			rt->tail = NULL;
		}
	}
	pthread_mutex_unlock(&rt->mu);
	return g;
}

static void local_push(wump_worker *w, wump_g *g) {
	pthread_mutex_lock(&w->q_mu);
	if (w->qtail - w->qhead < WUMP_LOCALQ) {
		w->q[w->qtail++ % WUMP_LOCALQ] = g;
		pthread_mutex_unlock(&w->q_mu);
		notify(w->rt);
	} else {
		pthread_mutex_unlock(&w->q_mu);
		global_push(w->rt, g);
	}
}

static wump_g *local_pop(wump_worker *w) {
	pthread_mutex_lock(&w->q_mu);
	wump_g *g = NULL;
	if (w->qhead != w->qtail) {
		g = w->q[w->qhead++ % WUMP_LOCALQ];
	}
	pthread_mutex_unlock(&w->q_mu);
	return g;
}

static wump_g *steal(wump_worker *w) {
	wump_runtime *rt = w->rt;
	for (int i = 0; i < rt->nprocs; i++) {
		unsigned index = w->steal_start++ % (unsigned)rt->nprocs;
		wump_worker *victim = &rt->workers[index];
		if (victim == w) {
			continue;
		}
		/* Only the owner writes this worker's tail. It has no local
		 * work when stealing, so taking half a victim always fits. */
		pthread_mutex_lock(&victim->q_mu);
		unsigned n = (victim->qtail - victim->qhead + 1) / 2;
		if (n == 0) {
			pthread_mutex_unlock(&victim->q_mu);
			continue;
		}
		wump_g *g = victim->q[victim->qhead++ % WUMP_LOCALQ];
		wump_g *batch[WUMP_LOCALQ / 2];
		for (unsigned j = 1; j < n; j++) {
			batch[j - 1] =
				victim->q[victim->qhead++ % WUMP_LOCALQ];
		}
		pthread_mutex_unlock(&victim->q_mu);
		/* Never hold two queue locks: simultaneous thieves can choose
		 * each other as victims. */
		pthread_mutex_lock(&w->q_mu);
		for (unsigned j = 1; j < n; j++) {
			w->q[w->qtail++ % WUMP_LOCALQ] = batch[j - 1];
		}
		pthread_mutex_unlock(&w->q_mu);
		return g;
	}
	return NULL;
}

static wump_g *find_work(wump_worker *w) {
	wump_g *g = NULL;
	if (++w->tick % 61 == 0) {
		g = global_pop(w->rt);
	}
	if (g == NULL) {
		g = local_pop(w);
	}
	if (g == NULL) {
		g = global_pop(w->rt);
	}
	if (g == NULL) {
		g = steal(w);
	}
	return g;
}

static void unregister_g(wump_runtime *rt, wump_g *g) {
	pthread_mutex_lock(&rt->mu);
	if (g->all_prev != NULL) {
		g->all_prev->all_next = g->all_next;
	} else {
		rt->all = g->all_next;
	}
	if (g->all_next != NULL) {
		g->all_next->all_prev = g->all_prev;
	}
	pthread_mutex_unlock(&rt->mu);
}

static void recycle(wump_worker *w, wump_g *g) {
#ifdef WUMP_TSAN
	__tsan_destroy_fiber(g->tsan_fiber);
	g->tsan_fiber = NULL;
#endif
#ifdef WUMP_ASAN
	__asan_unpoison_memory_region(g->stack_lo + 1,
		(size_t)((char *)g - (char *)(g->stack_lo + 1)));
#endif
	if (w->ngcache < WUMP_STACK_CACHE) {
		g->next = w->gcache;
		w->gcache = g;
		w->ngcache++;
	} else {
		unregister_g(w->rt, g);
		wump_stack_free(g);
	}
}

static void context_free(wump_g *g) {
	void (*cleanup)(void *) = g->context_free;
	void *arg = g->context_arg;
	g->context_enter = NULL;
	g->context_free = NULL;
	g->context_arg = NULL;
	if (cleanup != NULL) {
		cleanup(arg);
	}
}

#ifdef WUMP_ASAN
typedef struct wump_asan_retire {
	wump_g *g;
	void *sp, *fake_stack;
	const void *bottom;
	size_t size;
} wump_asan_retire;

/* Abandoned tasks cannot unwind their application frames. After context
 * cleanup, briefly re-enter a fresh trampoline on their mapped stack solely
 * to retire ASan's suspended fake stack through its public fiber API. */
static __attribute__((no_sanitize_address)) void asan_retire_entry(void *arg) {
	wump_asan_retire *retire = arg;
	wump_g *g = retire->g;
	__sanitizer_finish_switch_fiber(g->asan_fake_stack, &retire->bottom, &retire->size);
	g->asan_fake_stack = NULL;
	__sanitizer_start_switch_fiber(NULL, retire->bottom, retire->size);
	wump_ctx_switch(&g->sp, retire->sp);
	abort();
}

static void asan_retire(wump_g *g) {
	if (g->asan_fake_stack == NULL) return;
	wump_asan_retire retire = {.g = g};
	size_t size = (size_t)((char *)g - (char *)(g->stack_lo + 1));
	__asan_unpoison_memory_region(g->stack_lo + 1, size);
	void *sp = wump_ctx_init(g, asan_retire_entry, &retire);
	__sanitizer_start_switch_fiber(&retire.fake_stack, g->stack_lo + 1, size);
	wump_ctx_switch(&retire.sp, sp);
	__sanitizer_finish_switch_fiber(retire.fake_stack, NULL, NULL);
}
#endif

static void *machine_entry(void *arg);

/* rt->mu is held until the donor has committed the P handoff. A newly
 * created thread cannot start using its P before that unlock. */
static wump_machine *new_machine_locked(wump_runtime *rt, wump_worker *p) {
	wump_machine *m = calloc(1, sizeof(*m));
	if (m == NULL) {
		return NULL;
	}
	m->rt = rt;
	m->p = p;
	int error = pthread_cond_init(&m->wake, NULL);
	if (error != 0) {
		free(m);
		wump_set_errno(error);
		return NULL;
	}
	error = pthread_create(&m->thread, NULL, machine_entry, m);
	if (error != 0) {
		pthread_cond_destroy(&m->wake);
		free(m);
		wump_set_errno(error);
		return NULL;
	}
	m->next = rt->machines;
	rt->machines = m;
	return m;
}

static void switch_out(void) {
	wump_machine *m = current_machine();
	wump_g *g = m->cur;
	g->saved_errno = wump_errno();
#ifdef WUMP_TSAN
	__tsan_switch_to_fiber(m->tsan_sched_fiber, 0);
#endif
#ifdef WUMP_ASAN
	/* A completed task never resumes; let ASan release its fake stack. */
	__sanitizer_start_switch_fiber(g->state == G_DEAD ? NULL : &g->asan_fake_stack,
		m->asan_stack_bottom, m->asan_stack_size);
	if (g->state == G_DEAD) g->asan_fake_stack = NULL;
#endif
	wump_ctx_switch(&g->sp, m->sched_sp);
	/* A resumed task may be on another M. No cached TLS/M access here. */
#ifdef WUMP_ASAN
	m = current_machine();
	__sanitizer_finish_switch_fiber(g->asan_fake_stack,
		&m->asan_stack_bottom, &m->asan_stack_size);
#endif
}

static void task_entry(void *arg) {
	wump_g *g = arg;
#ifdef WUMP_ASAN
	wump_machine *initial = current_machine();
	__sanitizer_finish_switch_fiber(g->asan_fake_stack,
		&initial->asan_stack_bottom, &initial->asan_stack_size);
#endif
	g->fn(g->arg);
	wump_machine *m = current_machine();
	if (m->in_syscall) {
		stop(m->rt, EPROTO);
	}
	g->state = G_DEAD;
	switch_out();
	abort();
}

static wump_g *new_task(wump_worker *p, wump_fn fn, void *arg, size_t stack_size) {
	wump_g *g = p->gcache;
	if (g != NULL) {
		p->gcache = g->next;
		p->ngcache--;
	} else {
		g = wump_stack_new(stack_size);
		if (g == NULL) {
			return NULL;
		}
		pthread_mutex_lock(&p->rt->mu);
		g->all_next = p->rt->all;
		if (g->all_next != NULL) {
			g->all_next->all_prev = g;
		}
		p->rt->all = g;
		pthread_mutex_unlock(&p->rt->mu);
	}
	g->fn = fn;
	g->arg = arg;
	g->state = G_RUNNABLE;
	g->saved_errno = 0;
	g->cancel_fn = NULL;
	g->cancel_arg = NULL;
	g->context_enter = NULL;
	g->context_free = NULL;
	g->context_arg = NULL;
	*g->stack_lo = WUMP_STACK_CANARY;
	g->sp = wump_ctx_init(g, task_entry, g);
#ifdef WUMP_TSAN
	g->tsan_fiber = __tsan_create_fiber(0);
#endif
	return g;
}

static void schedule(wump_machine *m) {
	wump_runtime *rt = m->rt;
	current = m;
#ifdef WUMP_TSAN
	m->tsan_sched_fiber = __tsan_get_current_fiber();
#endif
	for (;;) {
		pthread_mutex_lock(&rt->mu);
		while (!atomic_load_explicit(&rt->stopping, memory_order_relaxed) &&
			(!rt->started || m->p == NULL)) {
			pthread_cond_wait(&m->wake, &rt->mu);
		}
		if (atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
			pthread_mutex_unlock(&rt->mu);
			break;
		}
		wump_worker *p = m->p;
		timers_expire_locked(rt);
		uint64_t epoch = rt->epoch;
		pthread_mutex_unlock(&rt->mu);
		wump_g *g = find_work(p);
		if (g == NULL) {
			pthread_mutex_lock(&rt->mu);
			if (epoch == rt->epoch &&
				!atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
				rt->idle++;
				if (rt->idle == rt->nprocs && rt->ntimers == 0 &&
					rt->io_waiters == 0 && rt->syscalls == 0) {
					stop_locked(rt, EDEADLK);
				} else if (rt->ntimers != 0) {
					int64_t deadline = rt->timers[0]->deadline;
					struct timespec until = {
						.tv_sec = (time_t)(deadline / INT64_C(1000000000)),
						.tv_nsec = (long)(deadline % INT64_C(1000000000))
					};
					int result = pthread_cond_timedwait(&rt->work, &rt->mu, &until);
					if (result != 0 && result != ETIMEDOUT) {
						abort();
					}
				} else {
					pthread_cond_wait(&rt->work, &rt->mu);
				}
				rt->idle--;
			}
			pthread_mutex_unlock(&rt->mu);
			continue;
		}
		m->cur = g;
		g->state = G_RUNNING;
		g->slice_start = 0;
		if (g->context_enter != NULL) {
			g->context_enter(g->context_arg);
		}
		wump_set_errno(g->saved_errno);
#ifdef WUMP_TSAN
		__tsan_switch_to_fiber(g->tsan_fiber, 0);
#endif
#ifdef WUMP_ASAN
		__sanitizer_start_switch_fiber(&m->asan_fake_stack, g->stack_lo + 1,
			(size_t)((char *)g - (char *)(g->stack_lo + 1)));
#endif
		wump_ctx_switch(&m->sched_sp, g->sp);
#ifdef WUMP_ASAN
		__sanitizer_finish_switch_fiber(m->asan_fake_stack, NULL, NULL);
#endif
		assert(*g->stack_lo == WUMP_STACK_CANARY);
		enum wump_gstate state = g->state;
		m->cur = NULL;
		if (m->in_syscall) {
			/* This M no longer owns p. Finish saving g before publishing
			 * it, and atomically remove the native-call liveness count. */
			assert(m->p == NULL && (state == G_RUNNABLE || state == G_DEAD));
			pthread_mutex_lock(&rt->mu);
			assert(rt->syscalls != 0);
			rt->syscalls--;
			m->in_syscall = 0;
			if (!atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
				assert(state == G_RUNNABLE);
				m->spare_next = rt->spare;
				rt->spare = m;
				global_push_locked(rt, g);
			}
			pthread_mutex_unlock(&rt->mu);
		} else if (state == G_WAITING) {
			/* A waker can reclaim g after the hook's final unlock. */
			void (*unlock)(void *) = m->park_fn;
			void *unlock_arg = m->park_arg;
			m->park_fn = NULL;
			m->park_arg = NULL;
			unlock(unlock_arg);
		} else if (state == G_RUNNABLE) {
			local_push(p, g);
		} else {
			assert(state == G_DEAD);
			context_free(g);
			if (g == rt->main_g) {
				stop(rt, 0);
			} else {
				recycle(p, g);
			}
		}
	}
	current = NULL;
}

static void *machine_entry(void *arg) {
	schedule(arg);
	return NULL;
}

wump_g *wump_self(void) {
	wump_machine *m = current_machine();
	return m != NULL && m->p != NULL && !m->in_syscall ? m->cur : NULL;
}

int wump_context_attach(void (*enter)(void *), void (*cleanup)(void *), void *arg) {
	wump_g *g = wump_self();
	if (g == NULL || enter == NULL || cleanup == NULL) {
		wump_set_errno(EINVAL);
		return -1;
	}
	if (g->context_enter != NULL) {
		wump_set_errno(EBUSY);
		return -1;
	}
	g->context_enter = enter;
	g->context_free = cleanup;
	g->context_arg = arg;
	return 0;
}

void wump_park(void (*unlock)(void *), void *arg) {
	wump_machine *m = current_machine();
	assert(wump_self() != NULL && unlock != NULL);
	m->park_fn = unlock;
	m->park_arg = arg;
	m->cur->state = G_WAITING;
	switch_out();
}

void wump_ready(wump_g *g) {
	g->state = G_RUNNABLE;
	local_push(current_machine()->p, g);
}

void wump_yield(void) {
	wump_g *g = wump_self();
	if (g != NULL) {
		g->state = G_RUNNABLE;
		switch_out();
	}
}

int wump_checkpoint(void) {
	wump_g *g = wump_self();
	if (g == NULL) {
		return 0;
	}
	if (!atomic_load_explicit(&current_machine()->rt->stopping, memory_order_acquire)) {
		int64_t now = wump_now();
		if (g->slice_start == 0) {
			g->slice_start = now;
			return 0;
		}
		if (now - g->slice_start < INT64_C(10000000)) {
			return 0;
		}
	}
	wump_yield();
	return 1;
}

int wump_go(wump_fn fn, void *arg) {
	return wump_go_context(fn, arg, NULL, NULL);
}

int wump_go_context(wump_fn fn, void *arg, void (*enter)(void *), void (*cleanup)(void *)) {
	if (wump_self() == NULL || fn == NULL || (enter == NULL) != (cleanup == NULL)) {
		wump_set_errno(EINVAL);
		return -1;
	}
	wump_worker *p = current_machine()->p;
	wump_g *g = new_task(p, fn, arg, WUMP_STACK_SIZE);
	if (g == NULL) {
		return -1;
	}
	g->context_enter = enter;
	g->context_free = cleanup;
	g->context_arg = arg;
	local_push(p, g);
	return 0;
}

int wump_nprocs(void) {
	wump_machine *m = current_machine();
	return m != NULL ? m->rt->nprocs : 0;
}

int wump_worker_id(void) {
	wump_machine *m = current_machine();
	return m != NULL && m->p != NULL ? m->p->id : -1;
}

int wump_syscall_enter(void) {
	int saved_errno = wump_errno();
	wump_machine *m = current_machine();
	if (m != NULL && m->in_syscall) {
		wump_set_errno(EBUSY);
		return -1;
	}
	if (wump_self() == NULL) {
		wump_set_errno(EINVAL);
		return -1;
	}
	wump_runtime *rt = m->rt;
	pthread_mutex_lock(&rt->mu);
	if (atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
		pthread_mutex_unlock(&rt->mu);
		wump_set_errno(ECANCELED);
		return -1;
	}
	wump_machine *replacement = rt->spare;
	if (replacement != NULL) {
		rt->spare = replacement->spare_next;
		replacement->spare_next = NULL;
		replacement->p = m->p;
	} else {
		replacement = new_machine_locked(rt, m->p);
		if (replacement == NULL) {
			int error = wump_errno();
			pthread_mutex_unlock(&rt->mu);
			wump_set_errno(error);
			return -1;
		}
	}
	m->cur->state = G_SYSCALL;
	m->in_syscall = 1;
	m->p = NULL;
	rt->syscalls++;
	pthread_cond_signal(&replacement->wake);
	pthread_mutex_unlock(&rt->mu);
	wump_set_errno(saved_errno);
	return 0;
}

int wump_syscall_exit(void) {
	wump_machine *m = current_machine();
	if (m == NULL || !m->in_syscall) {
		wump_set_errno(EINVAL);
		return -1;
	}
	m->cur->state = G_RUNNABLE;
	switch_out();
	return 0;
}

int wump_blocking(wump_fn fn, void *arg) {
	if (fn == NULL) {
		wump_set_errno(EINVAL);
		return -1;
	}
	if (wump_syscall_enter() != 0) {
		return -1;
	}
	fn(arg);
	return wump_syscall_exit();
}

int wump_run(wump_fn main_fn, void *arg, int nprocs) {
	if (current_machine() != NULL) {
		wump_set_errno(EBUSY);
		return -1;
	}
	if (main_fn == NULL || nprocs < 0) {
		wump_set_errno(EINVAL);
		return -1;
	}
	if (nprocs == 0) {
		long cpus = sysconf(_SC_NPROCESSORS_ONLN);
		if (cpus <= 0 || cpus > INT_MAX) {
			wump_set_errno(EINVAL);
			return -1;
		}
		nprocs = (int)cpus;
	}
	wump_runtime rt = { .nprocs = nprocs };
	wump_machine root = { .rt = &rt };
	atomic_init(&rt.stopping, 0);
	int error = pthread_mutex_init(&rt.mu, NULL);
	if (error != 0) {
		wump_set_errno(error);
		return -1;
	}
	pthread_condattr_t attr;
	error = pthread_condattr_init(&attr);
	if (error != 0) {
		pthread_mutex_destroy(&rt.mu);
		wump_set_errno(error);
		return -1;
	}
	error = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
	if (error == 0) {
		error = pthread_cond_init(&rt.work, &attr);
	}
	pthread_condattr_destroy(&attr);
	if (error != 0) {
		pthread_mutex_destroy(&rt.mu);
		wump_set_errno(error);
		return -1;
	}
	error = pthread_cond_init(&root.wake, NULL);
	if (error != 0) {
		goto destroy_runtime;
	}
	rt.machines = &root;
	if ((size_t)nprocs > SIZE_MAX / sizeof(*rt.workers)) {
		error = ENOMEM;
		goto destroy_runtime;
	}
	error = posix_memalign((void **)&rt.workers, _Alignof(wump_worker),
		(size_t)nprocs * sizeof(*rt.workers));
	if (error != 0) {
		goto destroy_runtime;
	}
	int initialized = 0;
	for (int i = 0; i < nprocs; i++) {
		wump_worker *p = &rt.workers[i];
		*p = (wump_worker){ .rt = &rt, .id = i, .steal_start = (unsigned)i + 1 };
		p->rng = ((uintptr_t)&rt ^ ((uint64_t)i + 1) * UINT64_C(0x9e3779b97f4a7c15)) | 1;
		error = pthread_mutex_init(&p->q_mu, NULL);
		if (error != 0) {
			goto destroy_workers;
		}
		initialized++;
	}
	root.p = &rt.workers[0];
	rt.main_g = new_task(root.p, main_fn, arg, WUMP_MAIN_STACK_SIZE);
	if (rt.main_g == NULL) {
		error = wump_errno();
		goto destroy_workers;
	}
	global_push(&rt, rt.main_g);
	pthread_mutex_lock(&rt.mu);
	for (int i = 1; i < nprocs; i++) {
		if (new_machine_locked(&rt, &rt.workers[i]) == NULL) {
			error = wump_errno();
			break;
		}
	}
	pthread_mutex_unlock(&rt.mu);
	if (error != 0) {
		stop(&rt, error);
	}
	pthread_mutex_lock(&rt.mu);
	rt.started = 1;
	for (wump_machine *m = rt.machines; m != NULL; m = m->next) {
		pthread_cond_signal(&m->wake);
	}
	pthread_mutex_unlock(&rt.mu);
	if (error == 0) {
		schedule(&root);
	}
	/* Stop prevents new handoffs, so this list is stable. Native calls
	 * must return before their threads/stacks can be reclaimed. */
	for (wump_machine *m = rt.machines; m != NULL; m = m->next) {
		if (m != &root && pthread_join(m->thread, NULL) != 0) {
			abort();
		}
	}
	error = rt.error;

destroy_workers:
	wump_poller_stop(rt.poller);
	for (wump_g *g = rt.all; g != NULL; g = g->all_next) {
		if (g->cancel_fn != NULL) {
			g->cancel_fn(g->cancel_arg);
		}
	}
	for (wump_g *g = rt.all; g != NULL; g = g->all_next) {
		context_free(g);
	}
	wump_poller_destroy(rt.poller);
	while (rt.all != NULL) {
		wump_g *g = rt.all;
		rt.all = g->all_next;
#ifdef WUMP_TSAN
		if (g->tsan_fiber != NULL) {
			__tsan_destroy_fiber(g->tsan_fiber);
		}
#endif
#ifdef WUMP_ASAN
		asan_retire(g);
#endif
		wump_stack_free(g);
	}
	for (int i = 0; i < initialized; i++) {
		pthread_mutex_destroy(&rt.workers[i].q_mu);
	}
	free(rt.workers);
destroy_runtime:
	while (rt.machines != NULL) {
		wump_machine *m = rt.machines;
		rt.machines = m->next;
		pthread_cond_destroy(&m->wake);
		if (m != &root) {
			free(m);
		}
	}
	free(rt.timers);
	pthread_cond_destroy(&rt.work);
	pthread_mutex_destroy(&rt.mu);
	if (error != 0) {
		wump_set_errno(error);
		return -1;
	}
	return 0;
}
