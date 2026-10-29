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
	SV *target;
	bool acquired;
} wump_lock_guard;

static void wump_lock_release(pTHX_ void *arg) {
	wump_lock_guard *guard = arg;
	wump_perl_lock *lock = guard->lock;
	SV *held = guard->target;
	bool acquired = guard->acquired;
	Safefree(guard);
	SvREFCNT_dec(held);
	if (!lock) return;
	wump_registry_lock();
	if (acquired) lock->owner = 0;
	if (--lock->guards) {
		wump_chan *token = lock->token;
		wump_registry_unlock();
		/* The scheduler cancels all waiters before running task destructors.
		 * Sending a token there would attempt to wake a canceled waiter. */
		if (acquired && wump_self() && wump_chan_send(token, NULL) != 0)
			croak("Wump: lock release failed");
		return;
	}
	wump_perl_lock **link = &wump_perl_active->locks;
	while (*link != lock) link = &(*link)->next;
	*link = lock->next;
	wump_registry_unlock();
	SV *target = lock->target;
	wump_chan_free(lock->token);
	Safefree(lock);
	SvREFCNT_dec(target);
}

void Perl_wump_lock(pTHX_ SV *value) {
	wump_schedule_check(aTHX);
	if (!wump_self() || PL_wump_task->finished)
		croak("Wump: lock requires a running task");
	wump_lock_guard *guard;
	Newxz(guard, 1, wump_lock_guard);
	SAVEDESTRUCTOR_X(wump_lock_release, guard);
	/* The current owner can be changing the value while another act tries
	 * to acquire its lock. Inspect flags under a reader claim, and wait for
	 * a transient writer instead of racing or rejecting normal lock use. */
	struct wump_shared *claim;
	bool magical;
	for (;;) {
		Perl_wump_memory_lock(aTHX);
		bool ready = Perl_wump_read_try_begin(aTHX_ value, &claim);
		if (ready) {
			magical = SvGMAGICAL(value);
			Perl_wump_read_end(aTHX_ claim);
		}
		Perl_wump_memory_unlock(aTHX);
		if (ready) break;
		wump_yield();
	}
	if (magical) SvGETMAGIC(value);
	SV *target;
	for (;;) {
		/* A writer must not acquire its mutation claim between our brief
		 * reader claim and its release: lock acquisition is not a user read
		 * that should make the current lock holder's update fail. */
		Perl_wump_memory_lock(aTHX);
		bool ready = Perl_wump_read_try_begin(aTHX_ value, &claim);
		if (ready) {
			target = SvROK(value) ? SvRV(value) : value;
			guard->target = SvREFCNT_inc(target);
			Perl_wump_read_end(aTHX_ claim);
		}
		Perl_wump_memory_unlock(aTHX);
		if (ready) break;
		wump_yield();
	}
	wump_registry_lock();
	wump_perl_lock *lock = wump_perl_active->locks;
	while (lock && lock->target != target) lock = lock->next;
	if (lock && lock->owner == PL_wump_task->id) {
		wump_registry_unlock();
		croak("Wump: lock is not reentrant");
	}
	if (!lock) {
		lock = calloc(1, sizeof(*lock));
		if (!lock) {
			wump_registry_unlock();
			croak("Wump: lock allocation failed");
		}
		lock->token = wump_chan_make(0, 1);
		if (!lock->token) {
			free(lock);
			wump_registry_unlock();
			croak("Wump: lock allocation failed");
		}
		lock->target = SvREFCNT_inc(target);
		lock->next = wump_perl_active->locks;
		wump_perl_active->locks = lock;
	}
	guard->lock = lock;
	lock->guards++;
	/* A newly installed lock has no previous owner and needs one token.
	 * Increment guards before exposing it so the first sender owns its life. */
	bool first = lock->guards == 1;
	wump_registry_unlock();
	if (first) {
		if (wump_chan_send(lock->token, NULL) != 0) croak("Wump: lock initialization failed");
	}
	if (wump_chan_recv(lock->token, NULL) != 1) croak("Wump: lock acquisition failed");
	guard->acquired = TRUE;
	wump_registry_lock();
	lock->owner = PL_wump_task->id;
	wump_registry_unlock();
}
