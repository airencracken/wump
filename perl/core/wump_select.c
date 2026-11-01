/* Selection buffers belong to this act. Runtime cancellation detaches every
 * native waiter before abandoned Perl frames unwind and free these buffers. */
typedef struct wump_perl_selection {
	wump_case *cases;
	wump_perl_message **values;
	AV *snapshot;
	size_t count;
	bool pending;
} wump_perl_selection;

static void wump_selection_clear(pTHX_ wump_perl_selection *work) {
	if (!work->pending && work->values) {
		for (size_t i = 0; i < work->count; i++) {
			wump_perl_message *message = work->values[i];
			if (!message) continue;
			work->values[i] = NULL;
			wump_registry_lock();
			if (message->previous) message->previous->next = message->next;
			else wump_perl_active->messages = message->next;
			if (message->next) message->next->previous = message->previous;
			wump_registry_unlock();
			SV *value = message->value;
			Safefree(message);
			/* Defer user cleanup until ordinary temporary cleanup, outside
			 * all native locks and after the result reaches the Perl stack. */
			if (value) sv_2mortal(value);
		}
	}
	/* A parked, abandoned selection may already have transferred its winning
	 * send, even though this C frame never resumed to observe the winner.
	 * Never dereference those pointers: the run's message registry owns the
	 * remaining candidates, and drains them after every act has unwound. */
	Safefree(work->values); work->values = NULL;
	Safefree(work->cases); work->cases = NULL;
	if (work->snapshot) {
		AV *snapshot = work->snapshot;
		work->snapshot = NULL;
		sv_2mortal((SV *)snapshot);
	}
}

static void wump_selection_free(pTHX_ void *arg) {
	wump_perl_selection *work = arg;
	wump_selection_clear(aTHX_ work);
	Safefree(work);
}

/* Called only inside the metadata region. No FETCH, overload or conversion
 * runs while snapshotting the case graph. Reject unsupported control magic. */
static void wump_selection_plain(pTHX_ SV *value, bool array) {
	Perl_wump_memory_check(aTHX_ value);
	bool plain = array ? SvTYPE(value) == SVt_PVAV && AvREAL((AV *)value) && !SvOBJECT(value)
		&& !Perl_wump_overlay_active(aTHX_ value)
		: SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
			&& !SvVALID(value) && !(SvROK(value) && SvWEAKREF(value));
	if (plain && SvTYPE(value) >= SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if (!Perl_wump_publish_magic(mg) && !(array &&
				(mg->mg_type == PERL_MAGIC_backref || Perl_wump_element_magic(mg)))) plain = FALSE;
		}
	}
	if (!plain) croak("Wump: selection requires plain case arrays and scalar fields");
}

static SV *wump_perl_select(pTHX_ SV *input, SV *timeout, SSize_t *chosen, bool *ok) {
	wump_schedule_check(aTHX);
	if (!wump_self() || !PL_wump_task) croak("Wump: selection requires a running task");
	SV *time = Perl_wump_xs_scalar(aTHX_ timeout, "selection timeout");
	if (!SvOK(time) || !looks_like_number(time)) croak("Wump: invalid selection timeout");
	NV seconds = SvNV(time);
	if (!isfinite(seconds) || (seconds < 0 && seconds != -1)
		|| seconds >= (NV)INT64_MAX / 1e9) croak("Wump: invalid selection timeout");
	int64_t duration = seconds == -1 ? -1 : (int64_t)(seconds * 1e9);
	I32 mark = PL_savestack_ix;
	wump_perl_selection *work;
	Newxz(work, 1, wump_perl_selection);
	SAVEDESTRUCTOR_X(wump_selection_free, work);
	I32 top = PL_savestack_ix;
	work->snapshot = newAV();
	struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
	wump_selection_plain(aTHX_ input, FALSE);
	if (!SvROK(input)) croak("Wump: selection requires an array reference");
	SV *referent = SvRV(input);
	wump_selection_plain(aTHX_ referent, TRUE);
	AV *outer = (AV *)referent;
	SSize_t last = AvFILLp(outer);
	work->count = (size_t)(last + 1);
	if (work->count > SIZE_MAX / sizeof(wump_case)
		|| work->count > SIZE_MAX / sizeof(wump_perl_message *)
		|| work->count > (size_t)SSize_t_MAX / 3) croak("Wump: too many selection cases");
	Newxz(work->cases, work->count, wump_case);
	Newxz(work->values, work->count, wump_perl_message *);
	for (size_t i = 0; i < work->count; i++) {
		SV *row = AvARRAY(outer)[i];
		if (!row) croak("Wump: invalid selection case");
		wump_selection_plain(aTHX_ row, FALSE);
		if (!SvROK(row)) croak("Wump: invalid selection case");
		SV *body = SvRV(row);
		wump_selection_plain(aTHX_ body, TRUE);
		AV *fields = (AV *)body;
		SSize_t length = AvFILLp(fields) + 1;
		if (length != 2 && length != 3) croak("Wump: invalid selection case arity");
		for (SSize_t j = 0; j < 3; j++) {
			SV *field = j < length && AvARRAY(fields)[j] ? AvARRAY(fields)[j] : &PL_sv_undef;
			wump_selection_plain(aTHX_ field, FALSE);
			av_push(work->snapshot, newSVsv(field));
		}
		SV *operation = AvARRAY(work->snapshot)[i * 3];
		if (SvROK(operation) || !SvPOK(operation)) croak("Wump: invalid selection operation");
		STRLEN size;
		const char *name = SvPV(operation, size);
		bool sending = size == 4 && memEQ(name, "send", 4);
		if (!sending && !(size == 4 && memEQ(name, "recv", 4))) croak("Wump: invalid selection operation");
		if (length != (sending ? 3 : 2)) croak("Wump: invalid selection case arity");
		work->cases[i].op = sending ? WUMP_SEND : WUMP_RECV;
		work->cases[i].data = &work->values[i];
	}
	Perl_wump_mutation_end(aTHX_ guard);
	/* Resolve every channel before publishing candidates or committing an
	 * operation. The private snapshot stays rooted across suspension. */
	for (size_t i = 0; i < work->count; i++) {
		SV *object = AvARRAY(work->snapshot)[i * 3 + 1];
		if (SvOK(object)) work->cases[i].ch = wump_perl_channel_get(aTHX_ object)->ch;
	}
	for (size_t i = 0; i < work->count; i++) {
		if (!work->cases[i].ch || work->cases[i].op != WUMP_SEND) continue;
		wump_perl_message *message;
		Newxz(message, 1, wump_perl_message);
		work->values[i] = message;
		wump_registry_lock();
		message->next = wump_perl_active->messages;
		if (message->next) message->next->previous = message;
		wump_perl_active->messages = message;
		wump_registry_unlock();
		message->value = newSVsv(AvARRAY(work->snapshot)[i * 3 + 2]);
		Perl_wump_publish(aTHX_ message->value);
	}
	size_t index = SIZE_MAX;
	work->pending = TRUE;
	int result = wump_sel(work->cases, work->count, duration, &index);
	bool sent = result == 1 && work->cases[index].op == WUMP_SEND && work->cases[index].result == 0;
	/* The receiver may already have freed the selected message. Forget it
	 * without dereferencing, before cleanup can inspect any remaining slot. */
	if (sent) work->values[index] = NULL;
	work->pending = FALSE;
	if (result < 0) croak("Wump: selection failed: %s", Strerror(wump_errno()));
	*chosen = result == 1 ? (SSize_t)index : -1;
	*ok = result == 1 && (sent || work->cases[index].result == 1);
	SV *value = &PL_sv_undef;
	if (result == 1 && work->cases[index].op == WUMP_SEND && !sent)
		croak("Wump: send on closed channel");
	if (result == 1 && work->cases[index].op == WUMP_RECV && *ok)
		value = sv_2mortal(newSVsv(work->values[index]->value));
	wump_selection_clear(aTHX_ work);
	if (PL_savestack_ix == top) LEAVE_SCOPE(mark);
	return value;
}

PP(pp_wumpsel) {
	dSP;
	SSize_t mark = SP - PL_stack_base - 2;
	U8 context = GIMME_V;
	SSize_t index;
	bool ok;
	SV *input = SP[-1], *timeout = SP[0];
	PUTBACK;
	SV *value = wump_perl_select(aTHX_ input, timeout, &index, &ok);
	SPAGAIN;
	SP = PL_stack_base + mark;
	if (context != G_VOID) {
		EXTEND(SP, 3);
		PUSHs(index < 0 ? &PL_sv_undef : sv_2mortal(newSVuv((UV)index)));
		if (context == G_LIST) { PUSHs(value); PUSHs(ok ? &PL_sv_yes : &PL_sv_no); }
	}
	RETURN;
}

static void xs_wump_select(pTHX_ CV *cv) {
	dXSARGS;
	PERL_UNUSED_ARG(cv);
	if (items != 2) croak("Usage: Wump::_sel(CASES, TIMEOUT)");
	SSize_t index;
	bool ok;
	SV *value = wump_perl_select(aTHX_ ST(0), ST(1), &index, &ok);
	SPAGAIN;
	EXTEND(SP, 3);
	ST(0) = index < 0 ? &PL_sv_undef : sv_2mortal(newSVuv((UV)index));
	if (GIMME_V == G_LIST) { ST(1) = value; ST(2) = ok ? &PL_sv_yes : &PL_sv_no; XSRETURN(3); }
	XSRETURN(1);
}
