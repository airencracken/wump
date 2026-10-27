/* Explicit wait groups. Membership is controlled by add/done, independently
 * of lexical blocks and act ancestry. Included by wump_core.c. */
typedef struct wump_perl_waitgroup {
	UV id, waiters;
	IV count;
	bool orphaned;
	pthread_mutex_t mu;
	wump_chan *ready;
	struct wump_perl_waitgroup *next;
} wump_perl_waitgroup;

static UV wump_waitgroup_id;

static void wump_waitgroup_free(wump_perl_waitgroup *group) {
	assert(group->waiters == 0);
	wump_chan_free(group->ready);
	if (pthread_mutex_destroy(&group->mu) != 0) abort();
	Safefree(group);
}

static void wump_waitgroup_retire(wump_perl_waitgroup *group) {
	wump_perl_waitgroup **link = &wump_perl_active->groups;
	while (*link != group) link = &(*link)->next;
	*link = group->next;
	wump_waitgroup_free(group);
}

static wump_perl_waitgroup *wump_waitgroup_get(pTHX_ SV *object) {
	if (!wump_perl_active || !wump_self() || !PL_wump_task)
		croak("Wump: wait group operation requires a running task");
	if (!SvROK(object) || !sv_derived_from(object, "Wump::WaitGroup")
		|| SvTYPE(SvRV(object)) >= SVt_PVAV)
		croak("Wump: invalid wait group");
	UV id = SvUV(SvRV(object));
	for (wump_perl_waitgroup *group = wump_perl_active->groups; group; group = group->next) {
		if (group->id == id && !group->orphaned) return group;
	}
	croak("Wump: wait group belongs to an inactive runtime");
}

static void xs_wump_waitgroup(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: Wump::WaitGroup->new()");
	if (!wump_perl_active || !wump_self() || !PL_wump_task)
		croak("Wump: waitgroup requires a running task");
	if (!SvOK(ST(0)) || SvROK(ST(0))) croak("Wump: invalid wait group class");
	if (wump_waitgroup_id == UV_MAX) croak("Wump: wait group id space exhausted");
	HV *stash = gv_stashsv(ST(0), GV_ADD);
	wump_perl_waitgroup *group;
	Newxz(group, 1, wump_perl_waitgroup);
	if (pthread_mutex_init(&group->mu, NULL) != 0) {
		Safefree(group);
		croak("Wump: wait group allocation failed");
	}
	group->id = ++wump_waitgroup_id;
	group->next = wump_perl_active->groups;
	wump_perl_active->groups = group;
	SV *id = newSVuv(group->id);
	SV *object = newRV_noinc(id);
	sv_bless(object, stash);
	SvREADONLY_on(id);
	ST(0) = sv_2mortal(object);
	XSRETURN(1);
}

static IV wump_waitgroup_delta(pTHX_ SV *value) {
	/* FETCH can execute Perl and schedule acts. Snapshot it once, before
	 * looking up native state or taking the counter mutex. */
	if (SvGMAGICAL(value)) value = sv_mortalcopy(value);
	if (!SvOK(value) || SvROK(value) || !looks_like_number(value))
		croak("Wump: invalid wait group delta");
	if (SvIOK(value)) {
		if (SvIsUV(value) && SvUV(value) > (UV)IV_MAX)
			croak("Wump: invalid wait group delta");
		return SvIV(value);
	}
	if (SvPOK(value)) {
		STRLEN length;
		const char *text = SvPV(value, length);
		UV whole;
		int flags = grok_number(text, length, &whole);
		if ((flags & IS_NUMBER_IN_UV) && !(flags & IS_NUMBER_NOT_INT)) {
			if (flags & IS_NUMBER_NEG) {
				if (whole > (UV)IV_MAX + 1) croak("Wump: invalid wait group delta");
				return whole == (UV)IV_MAX + 1 ? IV_MIN : -(IV)whole;
			}
			if (whole > (UV)IV_MAX) croak("Wump: invalid wait group delta");
			return (IV)whole;
		}
	}
	NV delta = SvNV(value);
	if (!isfinite(delta) || delta < (NV)IV_MIN || delta >= (NV)IV_MAX || trunc(delta) != delta)
		croak("Wump: invalid wait group delta");
	return (IV)delta;
}

static void wump_waitgroup_add(pTHX_ wump_perl_waitgroup *group, IV delta) {
	if (pthread_mutex_lock(&group->mu) != 0) abort();
	const char *error = NULL;
	if (delta < -group->count) error = "negative wait group counter";
	else if (delta > 0 && delta > IV_MAX - group->count) error = "wait group counter overflow";
	else if (delta > 0 && group->count == 0 && group->waiters)
		error = "wait group reused before previous waits returned";
	else if (delta > 0 && group->count == 0) {
		/* Each reuse gets a new notification channel. Closed channels
		 * broadcast completion to all waiters without scheduling here. */
		wump_chan *ready = wump_chan_make(0, 0);
		if (!ready) error = "wait group allocation failed";
		else {
			wump_chan_free(group->ready);
			group->ready = ready;
		}
	}
	if (!error) {
		group->count += delta;
		if (delta < 0 && group->count == 0 && wump_chan_close(group->ready) != 0) abort();
	}
	if (pthread_mutex_unlock(&group->mu) != 0) abort();
	if (error) croak("Wump: %s", error);
}

static void xs_wump_wg_add(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 2) croak("Usage: add(WAITGROUP, DELTA)");
	IV delta = wump_waitgroup_delta(aTHX_ ST(1));
	wump_perl_waitgroup *group = wump_waitgroup_get(aTHX_ ST(0));
	wump_waitgroup_add(aTHX_ group, delta);
	XSRETURN_EMPTY;
}

static void xs_wump_wg_done(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: done(WAITGROUP)");
	wump_waitgroup_add(aTHX_ wump_waitgroup_get(aTHX_ ST(0)), -1);
	XSRETURN_EMPTY;
}

typedef struct wump_waitgroup_waiter {
	wump_perl_waitgroup *group;
	bool registered;
} wump_waitgroup_waiter;

static void wump_waitgroup_wait_leave(pTHX_ void *arg) {
	wump_waitgroup_waiter *waiter = arg;
	wump_perl_waitgroup *group = waiter->group;
	bool retire = FALSE;
	if (waiter->registered) {
		if (pthread_mutex_lock(&group->mu) != 0) abort();
		assert(group->waiters);
		group->waiters--;
		retire = group->waiters == 0 && group->orphaned;
		if (pthread_mutex_unlock(&group->mu) != 0) abort();
	}
	Safefree(waiter);
	if (retire) wump_waitgroup_retire(group);
}

static void xs_wump_wg_wait(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: await(WAITGROUP)");
	wump_perl_waitgroup *group = wump_waitgroup_get(aTHX_ ST(0));
	if (pthread_mutex_lock(&group->mu) != 0) abort();
	bool empty = group->count == 0;
	if (pthread_mutex_unlock(&group->mu) != 0) abort();
	if (empty) XSRETURN_EMPTY;
	wump_waitgroup_waiter *waiter;
	Newxz(waiter, 1, wump_waitgroup_waiter);
	waiter->group = group;
	ENTER;
	SAVEDESTRUCTOR_X(wump_waitgroup_wait_leave, waiter);
	if (pthread_mutex_lock(&group->mu) != 0) abort();
	if (group->count == 0) {
		if (pthread_mutex_unlock(&group->mu) != 0) abort();
		LEAVE;
		XSRETURN_EMPTY;
	}
	group->waiters++;
	waiter->registered = TRUE;
	wump_chan *ready = group->ready;
	if (pthread_mutex_unlock(&group->mu) != 0) abort();
	int result = wump_chan_recv(ready, NULL);
	LEAVE;
	if (result != 0) croak("Wump: wait group wait failed");
	XSRETURN_EMPTY;
}

static void xs_wump_wg_destroy(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1 || !wump_perl_active || !SvROK(ST(0))
		|| SvTYPE(SvRV(ST(0))) >= SVt_PVAV) XSRETURN_EMPTY;
	UV id = SvUV(SvRV(ST(0)));
	wump_perl_waitgroup **link = &wump_perl_active->groups;
	while (*link && (*link)->id != id) link = &(*link)->next;
	if (*link) {
		wump_perl_waitgroup *group = *link;
		if (pthread_mutex_lock(&group->mu) != 0) abort();
		group->orphaned = TRUE;
		bool retire = group->waiters == 0;
		if (pthread_mutex_unlock(&group->mu) != 0) abort();
		if (retire) wump_waitgroup_retire(group);
	}
	XSRETURN_EMPTY;
}
