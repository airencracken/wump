#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

typedef struct waiter {
	struct waiter *prev, *next;
	wump_chan *ch;
	wump_g *g;
	void *data;
	int result;
	int queued;
	int sending;
} waiter;

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
	waiter *w = q->head;
	if (w != NULL) {
		unlink_waiter(q, w);
	}
	return w;
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
	/* Nothing in the resumed operation touches the channel. Clearing
	 * this hook permits freeing a closed channel before tasks resume. */
	w->g->cancel_fn = NULL;
	w->g->cancel_arg = NULL;
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

int wump_chan_send(wump_chan *ch, const void *elem) {
	if (!valid(ch, elem)) {
		return -1;
	}
	pthread_mutex_lock(&ch->mu);
	if (ch->closed) {
		pthread_mutex_unlock(&ch->mu);
		errno = EPIPE;
		return -1;
	}
	waiter *receiver = pop(&ch->receivers);
	if (receiver != NULL) {
		copy_value(ch, receiver->data, elem);
		wake(receiver, 1);
		pthread_mutex_unlock(&ch->mu);
		return 0;
	}
	if (ch->len < ch->cap) {
		copy_value(ch, slot(ch, ch->tail), elem);
		advance(&ch->tail, ch->cap);
		ch->len++;
		pthread_mutex_unlock(&ch->mu);
		return 0;
	}
	int result = park(ch, (void *)elem, 1);
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
		pthread_mutex_unlock(&ch->mu);
		return 1;
	}
	waiter *sender = pop(&ch->senders);
	if (sender != NULL) {
		copy_value(ch, out, sender->data);
		wake(sender, 0);
		pthread_mutex_unlock(&ch->mu);
		return 1;
	}
	if (ch->closed) {
		zero_value(ch, out);
		pthread_mutex_unlock(&ch->mu);
		return 0;
	}
	return park(ch, out, 0);
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
