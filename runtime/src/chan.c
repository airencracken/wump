#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

typedef struct selection selection;
typedef struct waiter {
	struct waiter *prev, *next;
	wump_chan *ch;
	wump_g *g;
	void *data;
	int result;
	int queued;
	int sending;
	selection *sel;
	size_t case_index;
} waiter;

typedef struct sel_slot {
	waiter wait;
	wump_chan *lock;
	size_t poll;
} sel_slot;

struct selection {
	_Atomic size_t winner;
	wump_g *g;
	sel_slot *slots;
	size_t ncases, nlocks;
	int result, error;
	int timed;
	int allocated;
	wump_timer timer;
};

typedef struct waitq {
	waiter *head, *tail;
} waitq;

struct wump_chan {
	pthread_mutex_t mu;
	size_t elem_size, cap, len, head, tail;
	unsigned char *buffer;
	int closed;
	waitq senders, receivers;
};

static void append(waitq *q, waiter *w) {
	w->prev = q->tail;
	w->next = NULL;
	w->queued = 1;
	if (q->tail != NULL) {
		q->tail->next = w;
	} else {
		q->head = w;
	}
	q->tail = w;
}

static void unlink_waiter(waitq *q, waiter *w) {
	if (w->prev != NULL) {
		w->prev->next = w->next;
	} else {
		q->head = w->next;
	}
	if (w->next != NULL) {
		w->next->prev = w->prev;
	} else {
		q->tail = w->prev;
	}
	w->queued = 0;
}

static waiter *pop(waitq *q) {
	while (q->head != NULL) {
		waiter *w = q->head;
		unlink_waiter(q, w);
		if (w->sel == NULL) {
			return w;
		}
		size_t expected = WUMP_SEL_PENDING;
		if (atomic_compare_exchange_strong(&w->sel->winner, &expected, w->case_index)) {
			return w;
		}
	}
	return NULL;
}

static void copy_value(wump_chan *ch, void *dst, const void *src) {
	if (ch->elem_size != 0) {
		memcpy(dst, src, ch->elem_size);
	}
}

static void zero_value(wump_chan *ch, void *dst) {
	if (ch->elem_size != 0) {
		memset(dst, 0, ch->elem_size);
	}
}

static void *slot(wump_chan *ch, size_t index) {
	/* A channel of zero-sized elements needs no backing storage. */
	return ch->elem_size == 0 ? NULL : ch->buffer + index * ch->elem_size;
}

static void advance(size_t *index, size_t cap) {
	if (++*index == cap) {
		*index = 0;
	}
}

static void wake(waiter *w, int result) {
	w->result = result;
	if (w->sel == NULL) {
		/* A resumed plain send/receive no longer touches the channel.
		 * Clearing its hook permits free before the task resumes. */
		w->g->cancel_fn = NULL;
		w->g->cancel_arg = NULL;
	} else {
		/* The selected task removes losing waiters and cancels its
		 * timer before returning. Shutdown needs the same hook. */
		w->sel->result = result;
	}
	wump_ready(w->g);
}

static void unlock_channel(void *arg) {
	wump_chan *ch = arg;
#ifdef WUMP_TSAN
	/* The OS thread still owns this mutex, but TSan treats scheduler
	 * and task fibers as different threads. Transfer its logical
	 * ownership across the stack switch without unlocking it early. */
	__tsan_mutex_pre_lock(&ch->mu, 0);
	__tsan_mutex_post_lock(&ch->mu, 0, 0);
#endif
	pthread_mutex_unlock(&ch->mu);
}

static void cancel_waiter(void *arg) {
	waiter *w = arg;
	wump_chan *ch = w->ch;
	pthread_mutex_lock(&ch->mu);
	if (w->queued) {
		unlink_waiter(w->sending ? &ch->senders : &ch->receivers, w);
	}
	pthread_mutex_unlock(&ch->mu);
}

static int park(wump_chan *ch, void *data, int sending) {
	wump_g *g = wump_self();
	waiter w = { .ch = ch, .g = g, .data = data, .sending = sending };
	append(sending ? &ch->senders : &ch->receivers, &w);
	g->cancel_fn = cancel_waiter;
	g->cancel_arg = &w;
#ifdef WUMP_TSAN
	__tsan_mutex_pre_unlock(&ch->mu, 0);
	__tsan_mutex_post_unlock(&ch->mu, 0);
#endif
	wump_park(unlock_channel, ch);
	return w.result;
}

wump_chan *wump_chan_make(size_t elem_size, size_t cap) {
	if (elem_size != 0 && cap > SIZE_MAX / elem_size) {
		errno = EOVERFLOW;
		return NULL;
	}
	wump_chan *ch = calloc(1, sizeof(*ch));
	if (ch == NULL) {
		return NULL;
	}
	if (elem_size != 0 && cap != 0) {
		ch->buffer = malloc(elem_size * cap);
		if (ch->buffer == NULL) {
			free(ch);
			return NULL;
		}
	}
	int error = pthread_mutex_init(&ch->mu, NULL);
	if (error != 0) {
		free(ch->buffer);
		free(ch);
		errno = error;
		return NULL;
	}
	ch->elem_size = elem_size;
	ch->cap = cap;
	return ch;
}

void wump_chan_free(wump_chan *ch) {
	if (ch != NULL) {
		/* A rendezvous can resume the peer before its waker has left
		 * the critical section. Wait for that final unlock before
		 * destroying the mutex/backing store. No new operations or
		 * parked waiters may exist when the owner frees a channel. */
		pthread_mutex_lock(&ch->mu);
		pthread_mutex_unlock(&ch->mu);
		pthread_mutex_destroy(&ch->mu);
		free(ch->buffer);
		free(ch);
	}
}

static int valid(wump_chan *ch, const void *data) {
	if (ch == NULL || wump_self() == NULL || (ch->elem_size != 0 && data == NULL)) {
		errno = EINVAL;
		return 0;
	}
	return 1;
}

static int try_send(wump_chan *ch, const void *elem, int *result) {
	if (ch->closed) {
		*result = -1;
		return 1;
	}
	waiter *receiver = pop(&ch->receivers);
	if (receiver != NULL) {
		copy_value(ch, receiver->data, elem);
		wake(receiver, 1);
		*result = 0;
		return 1;
	}
	if (ch->len < ch->cap) {
		copy_value(ch, slot(ch, ch->tail), elem);
		advance(&ch->tail, ch->cap);
		ch->len++;
		*result = 0;
		return 1;
	}
	return 0;
}

static int try_recv(wump_chan *ch, void *out, int *result) {
	if (ch->len != 0) {
		copy_value(ch, out, slot(ch, ch->head));
		advance(&ch->head, ch->cap);
		ch->len--;
		/* A sender blocked behind a full buffer takes the newly free
		 * slot; the receiver must still observe the oldest value. */
		waiter *sender = pop(&ch->senders);
		if (sender != NULL) {
			copy_value(ch, slot(ch, ch->tail), sender->data);
			advance(&ch->tail, ch->cap);
			ch->len++;
			wake(sender, 0);
		}
		*result = 1;
		return 1;
	}
	waiter *sender = pop(&ch->senders);
	if (sender != NULL) {
		copy_value(ch, out, sender->data);
		wake(sender, 0);
		*result = 1;
		return 1;
	}
	if (ch->closed) {
		zero_value(ch, out);
		*result = 0;
		return 1;
	}
	return 0;
}

int wump_chan_send(wump_chan *ch, const void *elem) {
	if (!valid(ch, elem)) {
		return -1;
	}
	pthread_mutex_lock(&ch->mu);
	int result;
	if (try_send(ch, elem, &result)) {
		pthread_mutex_unlock(&ch->mu);
	} else {
		result = park(ch, (void *)elem, 1);
	}
	if (result == -1) {
		errno = EPIPE;
	}
	return result;
}

int wump_chan_recv(wump_chan *ch, void *out) {
	if (!valid(ch, out)) {
		return -1;
	}
	pthread_mutex_lock(&ch->mu);
	int result;
	if (try_recv(ch, out, &result)) {
		pthread_mutex_unlock(&ch->mu);
	} else {
		result = park(ch, out, 0);
	}
	return result;
}

int wump_chan_close(wump_chan *ch) {
	if (ch == NULL || wump_self() == NULL) {
		errno = EINVAL;
		return -1;
	}
	pthread_mutex_lock(&ch->mu);
	if (ch->closed) {
		pthread_mutex_unlock(&ch->mu);
		errno = EPIPE;
		return -1;
	}
	ch->closed = 1;
	waiter *w;
	while ((w = pop(&ch->receivers)) != NULL) {
		zero_value(ch, w->data);
		wake(w, 0);
	}
	while ((w = pop(&ch->senders)) != NULL) {
		wake(w, -1);
	}
	pthread_mutex_unlock(&ch->mu);
	return 0;
}

size_t wump_chan_len(wump_chan *ch) {
	if (ch == NULL) {
		return 0;
	}
	pthread_mutex_lock(&ch->mu);
	size_t len = ch->len;
	pthread_mutex_unlock(&ch->mu);
	return len;
}

size_t wump_chan_cap(wump_chan *ch) {
	return ch != NULL ? ch->cap : 0;
}

static int compare_slots(const void *a, const void *b) {
	uintptr_t left = (uintptr_t)((const sel_slot *)a)->wait.ch;
	uintptr_t right = (uintptr_t)((const sel_slot *)b)->wait.ch;
	return (left > right) - (left < right);
}

static void lock_selection(sel_slot *slots, size_t nlocks) {
	for (size_t i = 0; i < nlocks; i++) {
		pthread_mutex_lock(&slots[i].lock->mu);
	}
}

static void unlock_selection(sel_slot *slots, size_t nlocks, int transferred) {
	/* After the final unlock a resumed selection can free slots. All
	 * loop bounds and pointers must be local before releasing locks. */
	for (size_t i = nlocks; i != 0; i--) {
		wump_chan *ch = slots[i - 1].lock;
		if (transferred) {
			unlock_channel(ch);
		} else {
			pthread_mutex_unlock(&ch->mu);
		}
	}
}

static void detach_selection(void *arg) {
	selection *sel = arg;
	lock_selection(sel->slots, sel->nlocks);
	wump_timer_cancel(&sel->timer);
	for (size_t i = 0; i < sel->ncases; i++) {
		waiter *w = &sel->slots[i].wait;
		if (w->queued) {
			unlink_waiter(w->sending ? &w->ch->senders : &w->ch->receivers, w);
		}
	}
	unlock_selection(sel->slots, sel->nlocks, 0);
	sel->g->cancel_fn = NULL;
	sel->g->cancel_arg = NULL;
	if (sel->allocated) {
		free(sel->slots);
	}
}

static void park_selection(void *arg) {
	selection *sel = arg;
	sel_slot *slots = sel->slots;
	size_t nlocks = sel->nlocks;
	wump_g *g = sel->g;
	int failed = 0;
	/* Register timers only after the context is saved. Unlike channel
	 * wakers, expiry does not need a channel lock and could otherwise
	 * dispatch this task while it was still running on its own stack. */
	if (sel->timed && wump_timer_add(&sel->timer) != 0) {
		sel->error = errno;
		atomic_store(&sel->winner, WUMP_SEL_ERROR);
		failed = 1;
	}
	/* A timer can already have won. Only use captured locals now. */
	unlock_selection(slots, nlocks, 1);
	if (failed) {
		wump_ready(g);
	}
}

int wump_sel(wump_case *cases, size_t ncases, int64_t timeout_ns, size_t *chosen) {
	wump_g *g = wump_self();
	if (g == NULL || (ncases != 0 && cases == NULL) || timeout_ns < -1) {
		errno = EINVAL;
		return -1;
	}
	if (ncases > SIZE_MAX / sizeof(sel_slot)) {
		errno = EOVERFLOW;
		return -1;
	}
	for (size_t i = 0; i < ncases; i++) {
		if ((cases[i].op != WUMP_SEND && cases[i].op != WUMP_RECV) ||
			(cases[i].ch != NULL && cases[i].ch->elem_size != 0 && cases[i].data == NULL)) {
			errno = EINVAL;
			return -1;
		}
	}
	int64_t deadline = 0;
	if (timeout_ns > 0) {
		int64_t now = wump_now();
		if (timeout_ns > INT64_MAX - now) {
			errno = EOVERFLOW;
			return -1;
		}
		deadline = now + timeout_ns;
	}
	sel_slot small[8];
	sel_slot *slots = small;
	if (ncases > sizeof(small) / sizeof(small[0])) {
		slots = calloc(ncases, sizeof(*slots));
		if (slots == NULL) {
			return -1;
		}
	}
	selection sel = {
		.g = g, .slots = slots, .ncases = ncases,
		.timed = timeout_ns > 0, .allocated = slots != small,
		.timer = { .g = g, .deadline = deadline, .index = SIZE_MAX }
	};
	atomic_init(&sel.winner, WUMP_SEL_PENDING);
	sel.timer.winner = &sel.winner;
	for (size_t i = 0; i < ncases; i++) {
		slots[i] = (sel_slot){ .wait = {
			.ch = cases[i].ch, .g = g, .data = cases[i].data,
			.sending = cases[i].op == WUMP_SEND, .sel = &sel, .case_index = i
		} };
	}
	qsort(slots, ncases, sizeof(*slots), compare_slots);
	for (size_t i = 0; i < ncases; i++) {
		wump_chan *ch = slots[i].wait.ch;
		if (ch != NULL && (i == 0 || ch != slots[i - 1].wait.ch)) {
			slots[sel.nlocks++].lock = ch;
		}
		slots[i].poll = i;
	}
	for (size_t i = 1; i < ncases; i++) {
		size_t other = wump_random() % (i + 1);
		size_t tmp = slots[i].poll;
		slots[i].poll = slots[other].poll;
		slots[other].poll = tmp;
	}
	lock_selection(slots, sel.nlocks);
	for (size_t i = 0; i < ncases; i++) {
		waiter *w = &slots[slots[i].poll].wait;
		if (w->ch == NULL) {
			continue;
		}
		int result;
		int ready = w->sending ? try_send(w->ch, w->data, &result) :
			try_recv(w->ch, w->data, &result);
		if (ready) {
			size_t index = w->case_index;
			unlock_selection(slots, sel.nlocks, 0);
			if (sel.allocated) {
				free(slots);
			}
			cases[index].result = result;
			if (chosen != NULL) {
				*chosen = index;
			}
			if (result == -1) {
				errno = EPIPE;
			}
			return 1;
		}
	}
	if (timeout_ns == 0) {
		unlock_selection(slots, sel.nlocks, 0);
		if (sel.allocated) {
			free(slots);
		}
		if (chosen != NULL) {
			*chosen = SIZE_MAX;
		}
		return 0;
	}
	for (size_t i = 0; i < ncases; i++) {
		/* Enqueue in randomized order, including duplicate cases, so
		 * peers do not permanently favor an earlier duplicate. */
		waiter *w = &slots[slots[i].poll].wait;
		if (w->ch != NULL) {
			append(w->sending ? &w->ch->senders : &w->ch->receivers, w);
		}
	}
	g->cancel_fn = detach_selection;
	g->cancel_arg = &sel;
#ifdef WUMP_TSAN
	for (size_t i = 0; i < sel.nlocks; i++) {
		__tsan_mutex_pre_unlock(&slots[i].lock->mu, 0);
		__tsan_mutex_post_unlock(&slots[i].lock->mu, 0);
	}
#endif
	wump_park(park_selection, &sel);
	detach_selection(&sel);
	size_t winner = atomic_load(&sel.winner);
	if (winner == WUMP_SEL_ERROR) {
		errno = sel.error;
		return -1;
	}
	if (winner == WUMP_SEL_TIMEOUT) {
		if (chosen != NULL) {
			*chosen = SIZE_MAX;
		}
		return 0;
	}
	cases[winner].result = sel.result;
	if (chosen != NULL) {
		*chosen = winner;
	}
	if (sel.result == -1) {
		errno = EPIPE;
	}
	return 1;
}

int wump_sleep(int64_t duration_ns) {
	if (wump_self() == NULL || duration_ns < 0) {
		errno = EINVAL;
		return -1;
	}
	if (duration_ns == 0) {
		wump_yield();
		return 0;
	}
	return wump_sel(NULL, 0, duration_ns, NULL) == -1 ? -1 : 0;
}
