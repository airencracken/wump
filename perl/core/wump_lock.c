/* A lock protects an SV identity, independently of its value or task overlay.
 * A guard is installed before parking, so shutdown also releases waiters.
 * The registry owns the referent only while there are guards. */
typedef struct wump_perl_lock {
	SV *target;
	wump_chan *token;
	UV owner;
	size_t guards;
	struct wump_perl_lock *next;
} wump_perl_lock;

typedef struct wump_lock_guard {
	wump_perl_lock *lock;
	bool acquired;
} wump_lock_guard;

static void wump_lock_release(pTHX_ void *arg) {
	wump_lock_guard *guard = arg;
	wump_perl_lock *lock = guard->lock;
	bool acquired = guard->acquired;
	Safefree(guard);
	if (!lock) return;
	if (acquired) lock->owner = 0;
	if (--lock->guards) {
		/* The scheduler cancels all waiters before running task destructors.
		 * Sending a token there would attempt to wake a canceled waiter. */
		if (acquired && wump_self() && wump_chan_send(lock->token, NULL) != 0)
			croak("Wump: lock release failed");
		return;
	}
	wump_perl_lock **link = &wump_perl_active->locks;
	while (*link != lock) link = &(*link)->next;
	*link = lock->next;
	SV *target = lock->target;
	wump_chan_free(lock->token);
	Safefree(lock);
	SvREFCNT_dec(target);
}

void Perl_wump_lock(pTHX_ SV *value) {
	if (!wump_self() || PL_wump_task->finished)
		croak("Wump: lock requires a running task");
	SvGETMAGIC(value);
	SV *target = SvROK(value) ? SvRV(value) : value;
	wump_perl_lock *lock = wump_perl_active->locks;
	while (lock && lock->target != target) lock = lock->next;
	if (lock && lock->owner == PL_wump_task->id)
		croak("Wump: lock is not reentrant");
	wump_lock_guard *guard;
	Newxz(guard, 1, wump_lock_guard);
	SAVEDESTRUCTOR_X(wump_lock_release, guard);
	if (!lock) {
		Newxz(lock, 1, wump_perl_lock);
		lock->target = SvREFCNT_inc(target);
		lock->next = wump_perl_active->locks;
		wump_perl_active->locks = lock;
	}
	guard->lock = lock;
	lock->guards++;
	if (!lock->token) {
		lock->token = wump_chan_make(0, 1);
		if (!lock->token) croak("Wump: lock allocation failed");
		if (wump_chan_send(lock->token, NULL) != 0) croak("Wump: lock initialization failed");
	}
	if (wump_chan_recv(lock->token, NULL) != 1) croak("Wump: lock acquisition failed");
	guard->acquired = TRUE;
	lock->owner = PL_wump_task->id;
}
