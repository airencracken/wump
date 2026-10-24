#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

#include "internal.h"

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
};

static _Thread_local wump_worker *current;

static void notify(wump_runtime *rt) {
	pthread_mutex_lock(&rt->mu);
	rt->epoch++;
	pthread_cond_signal(&rt->work);
	pthread_mutex_unlock(&rt->mu);
}

static void stop(wump_runtime *rt, int error) {
	pthread_mutex_lock(&rt->mu);
	if (!atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
		rt->error = error;
		atomic_store_explicit(&rt->stopping, 1, memory_order_release);
	}
	pthread_cond_broadcast(&rt->work);
	pthread_mutex_unlock(&rt->mu);
}

static void global_push(wump_runtime *rt, wump_g *g) {
	g->next = NULL;
	pthread_mutex_lock(&rt->mu);
	if (rt->tail != NULL) {
		rt->tail->next = g;
	} else {
		rt->head = g;
	}
	rt->tail = g;
	rt->epoch++;
	pthread_cond_signal(&rt->work);
	pthread_mutex_unlock(&rt->mu);
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
	if (w->ngcache < WUMP_STACK_CACHE) {
		g->next = w->gcache;
		w->gcache = g;
		w->ngcache++;
	} else {
		unregister_g(w->rt, g);
		wump_stack_free(g);
	}
}

static void switch_out(void) {
	/* Do not use a cached worker/TLS address after switching: a task
	 * can resume on another OS thread. The scheduler restores errno. */
	wump_worker *w = current;
	wump_g *g = w->cur;
	g->saved_errno = errno;
#ifdef WUMP_TSAN
	__tsan_switch_to_fiber(w->tsan_sched_fiber, 0);
#endif
	wump_ctx_switch(&g->sp, w->sched_sp);
}

static void task_entry(void *arg) {
	wump_g *g = arg;
	g->fn(g->arg);
	g->state = G_DEAD;
	switch_out();
	abort();
}

static wump_g *new_task(wump_worker *w, wump_fn fn, void *arg, size_t stack_size) {
	wump_g *g = w->gcache;
	if (g != NULL) {
		w->gcache = g->next;
		w->ngcache--;
	} else {
		g = wump_stack_new(stack_size);
		if (g == NULL) {
			return NULL;
		}
		pthread_mutex_lock(&w->rt->mu);
		g->all_next = w->rt->all;
		if (g->all_next != NULL) {
			g->all_next->all_prev = g;
		}
		w->rt->all = g;
		pthread_mutex_unlock(&w->rt->mu);
	}
	g->fn = fn;
	g->arg = arg;
	g->state = G_RUNNABLE;
	g->saved_errno = 0;
	g->cancel_fn = NULL;
	g->cancel_arg = NULL;
	*g->stack_lo = WUMP_STACK_CANARY;
	g->sp = wump_ctx_init(g, task_entry, g);
#ifdef WUMP_TSAN
	g->tsan_fiber = __tsan_create_fiber(0);
#endif
	return g;
}

static void schedule(wump_worker *w) {
	wump_runtime *rt = w->rt;
	current = w;
#ifdef WUMP_TSAN
	w->tsan_sched_fiber = __tsan_get_current_fiber();
#endif
	while (!atomic_load_explicit(&rt->stopping, memory_order_acquire)) {
		/* Pair the work scan with an epoch under the sleep mutex.
		 * Every enqueue changes it, preventing a lost wakeup. */
		pthread_mutex_lock(&rt->mu);
		uint64_t epoch = rt->epoch;
		pthread_mutex_unlock(&rt->mu);
		wump_g *g = find_work(w);
		if (g == NULL) {
			pthread_mutex_lock(&rt->mu);
			if (epoch == rt->epoch &&
				!atomic_load_explicit(&rt->stopping, memory_order_relaxed)) {
				rt->idle++;
				if (rt->idle == rt->nprocs) {
					rt->error = EDEADLK;
					atomic_store_explicit(&rt->stopping, 1, memory_order_release);
					pthread_cond_broadcast(&rt->work);
				} else {
					pthread_cond_wait(&rt->work, &rt->mu);
				}
				rt->idle--;
			}
			pthread_mutex_unlock(&rt->mu);
			continue;
		}
		w->cur = g;
		g->state = G_RUNNING;
		errno = g->saved_errno;
#ifdef WUMP_TSAN
		__tsan_switch_to_fiber(g->tsan_fiber, 0);
#endif
		wump_ctx_switch(&w->sched_sp, g->sp);
		/* A waker can run and even free g as soon as the park hook
		 * unlocks its channel. Finish every access to g first. */
		assert(*g->stack_lo == WUMP_STACK_CANARY);
		enum wump_gstate state = g->state;
		w->cur = NULL;
		if (state == G_WAITING) {
			void (*unlock)(void *) = w->park_fn;
			void *unlock_arg = w->park_arg;
			w->park_fn = NULL;
			w->park_arg = NULL;
			unlock(unlock_arg);
		} else if (state == G_RUNNABLE) {
			local_push(w, g);
		} else {
			assert(state == G_DEAD);
			if (g == rt->main_g) {
				stop(rt, 0);
			} else {
				recycle(w, g);
			}
		}
	}
	current = NULL;
}

static void *worker_entry(void *arg) {
	wump_worker *w = arg;
	pthread_mutex_lock(&w->rt->mu);
	while (!w->rt->started) {
		pthread_cond_wait(&w->rt->work, &w->rt->mu);
	}
	pthread_mutex_unlock(&w->rt->mu);
	schedule(w);
	return NULL;
}

wump_g *wump_self(void) {
	return current != NULL ? current->cur : NULL;
}

void wump_park(void (*unlock)(void *), void *arg) {
	wump_worker *w = current;
	assert(w != NULL && w->cur != NULL && unlock != NULL);
	w->park_fn = unlock;
	w->park_arg = arg;
	w->cur->state = G_WAITING;
	switch_out();
}

void wump_ready(wump_g *g) {
	g->state = G_RUNNABLE;
	local_push(current, g);
}

void wump_yield(void) {
	if (current != NULL && current->cur != NULL) {
		current->cur->state = G_RUNNABLE;
		switch_out();
	}
}

int wump_go(wump_fn fn, void *arg) {
	if (wump_self() == NULL || fn == NULL) {
		errno = EINVAL;
		return -1;
	}
	wump_g *g = new_task(current, fn, arg, WUMP_STACK_SIZE);
	if (g == NULL) {
		return -1;
	}
	local_push(current, g);
	return 0;
}

int wump_nprocs(void) {
	return current != NULL ? current->rt->nprocs : 0;
}

int wump_worker_id(void) {
	return current != NULL ? current->id : -1;
}

int wump_run(wump_fn main_fn, void *arg, int nprocs) {
	if (current != NULL) {
		errno = EBUSY;
		return -1;
	}
	if (main_fn == NULL || nprocs < 0) {
		errno = EINVAL;
		return -1;
	}
	if (nprocs == 0) {
		long cpus = sysconf(_SC_NPROCESSORS_ONLN);
		if (cpus <= 0 || cpus > INT_MAX) {
			errno = EINVAL;
			return -1;
		}
		nprocs = (int)cpus;
	}
	wump_runtime rt = { .nprocs = nprocs };
	atomic_init(&rt.stopping, 0);
	int error = pthread_mutex_init(&rt.mu, NULL);
	if (error != 0) {
		errno = error;
		return -1;
	}
	error = pthread_cond_init(&rt.work, NULL);
	if (error != 0) {
		pthread_mutex_destroy(&rt.mu);
		errno = error;
		return -1;
	}
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
		wump_worker *w = &rt.workers[i];
		*w = (wump_worker){ .rt = &rt, .id = i, .steal_start = (unsigned)i + 1 };
		error = pthread_mutex_init(&w->q_mu, NULL);
		if (error != 0) {
			goto destroy_workers;
		}
		initialized++;
	}
	rt.main_g = new_task(&rt.workers[0], main_fn, arg, WUMP_MAIN_STACK_SIZE);
	if (rt.main_g == NULL) {
		error = errno;
		goto destroy_workers;
	}
	global_push(&rt, rt.main_g);
	int created = 0;
	for (int i = 1; i < nprocs; i++) {
		error = pthread_create(&rt.workers[i].thread, NULL, worker_entry,
			&rt.workers[i]);
		if (error != 0) {
			stop(&rt, error);
			break;
		}
		created++;
	}
	pthread_mutex_lock(&rt.mu);
	rt.started = 1;
	pthread_cond_broadcast(&rt.work);
	pthread_mutex_unlock(&rt.mu);
	if (error == 0) {
		schedule(&rt.workers[0]);
	}
	for (int i = 1; i <= created; i++) {
		int joined = pthread_join(rt.workers[i].thread, NULL);
		/* With owned, joinable threads this signals an internal bug. */
		if (joined != 0) {
			abort();
		}
	}
	error = rt.error;

destroy_workers:
	/* No worker can touch a channel or a coroutine now. Unlink parked
	 * stack-resident waiters before unmapping their stacks, so channels
	 * owned by the caller remain reusable after early exit/deadlock. */
	for (wump_g *g = rt.all; g != NULL; g = g->all_next) {
		if (g->cancel_fn != NULL) {
			g->cancel_fn(g->cancel_arg);
		}
	}
	while (rt.all != NULL) {
		wump_g *g = rt.all;
		rt.all = g->all_next;
#ifdef WUMP_TSAN
		if (g->tsan_fiber != NULL) {
			__tsan_destroy_fiber(g->tsan_fiber);
		}
#endif
		wump_stack_free(g);
	}
	for (int i = 0; i < initialized; i++) {
		pthread_mutex_destroy(&rt.workers[i].q_mu);
	}
	free(rt.workers);
destroy_runtime:
	pthread_cond_destroy(&rt.work);
	pthread_mutex_destroy(&rt.mu);
	if (error != 0) {
		errno = error;
		return -1;
	}
	return 0;
}
