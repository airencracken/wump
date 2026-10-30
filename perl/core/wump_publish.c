/* Publication metadata carries no Perl references. Walk raw storage without
 * FETCH, overloaded conversion, hash iteration, or scheduler callbacks.
 * All counters remain atomic while this barrier is being brought up. */
enum { WUMP_PUBLISH_PENDING = 1, WUMP_PUBLISH_SHARED = 2 };
static _Thread_local PerlInterpreter *wump_publisher;

bool Perl_wump_publish_active(pTHX) {
	return wump_publisher == aTHX;
}

typedef struct wump_publish_work {
	SV **values;
	size_t used, capacity;
	bool complete;
	bool locked;
	PerlInterpreter *previous;
} wump_publish_work;

static int wump_publish_set(pTHX_ SV *value, MAGIC *mg);
static int wump_publish_copy(pTHX_ SV *value, MAGIC *mg, SV *copy,
	const char *key, I32 length);
static int wump_publish_local(pTHX_ SV *value, MAGIC *mg);
static int wump_publish_free(pTHX_ SV *value, MAGIC *mg) {
	PERL_UNUSED_ARG(mg);
	/* Pad CVs can be cleared and reused without returning their head to the
	 * allocator. Their old publication classification ends with the marker. */
	Perl_wump_memory_mark(aTHX_ value, 0);
	return 0;
}
static const MGVTBL wump_publish_vtbl = {
	.svt_set = wump_publish_set,
	.svt_copy = wump_publish_copy,
	.svt_local = wump_publish_local,
	.svt_free = wump_publish_free,
};

bool Perl_wump_publish_magic(const MAGIC *mg) {
	return mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == &wump_publish_vtbl;
}

static MAGIC *wump_publish_marker(const SV *value) {
	if (!value || SvTYPE(value) < SVt_PVMG) return NULL;
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
		if (Perl_wump_publish_magic(mg)) return mg;
	return NULL;
}

static bool wump_memory_published(pTHX_ const SV *value) {
	if (wump_memory_untracked(aTHX->Iwump_memory, value)) return FALSE;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	bool published = node && node->state == WUMP_PUBLISH_SHARED;
	bool busy = node && (atomic_load_explicit(&node->access, memory_order_acquire) & WUMP_WRITER)
		&& node->writer != wump_memory_actor(aTHX);
	if (published && !busy) {
		/* Native registration can install claims without a graph walk.
		 * Only the completed publication marker certifies outgoing edges. */
		MAGIC *marker = wump_publish_marker(value);
		published = marker && marker->mg_private == WUMP_PUBLISH_SHARED;
	}
	Perl_wump_memory_unlock(aTHX);
	if (busy) croak("Wump: publication overlaps mutation of a shared value");
	return published;
}

bool Perl_wump_is_shared(pTHX_ const SV *value) {
	if (!value) return FALSE;
	if (aTHX->Iwump_memory) Perl_wump_memory_lock(aTHX);
	int shared = Perl_wump_memory_shared(aTHX_ value);
	if (shared >= 0) {
		Perl_wump_memory_unlock(aTHX);
		return shared;
	}
	bool result;
	if (SvIMMORTAL(value)) result = TRUE;
	/* Native inversion lists contain no SV edges and cannot carry magic. */
	else if (SvTYPE(value) == SVt_INVLIST) result = TRUE;
	else
	if ((SvTYPE(value) == SVt_PVHV && HvNAME_HEK((HV *)value))
		|| isGV_with_GP(value)) result = TRUE;
	else {
		MAGIC *mg = wump_publish_marker(value);
		result = mg && mg->mg_private == WUMP_PUBLISH_SHARED;
	}
	if (aTHX->Iwump_memory) Perl_wump_memory_unlock(aTHX);
	return result;
}

static void wump_publish_queue(pTHX_ wump_publish_work *work, SV *value) {
	if (!value) return;
	Perl_wump_memory_check(aTHX_ value);
	if (SvIS_FREED(value) || SvIMMORTAL(value)) return;
	if (SvTYPE(value) == SVt_INVLIST) return;
	/* Stash entry types encode compiler state (NULL versus a forward
	 * declaration). Never upgrade them merely to attach metadata. Package
	 * value slots are published separately through the GV accessors. */
	if ((SvTYPE(value) == SVt_PVHV && HvNAME_HEK((HV *)value))
		|| isGV_with_GP(value)) return;
	MAGIC *mg = wump_publish_marker(value);
	if (mg && mg->mg_private) return;
	if (PL_wump_task && SvTEMP(value)) {
		/* The creating act's mortal reference must not later clear TEMP on
		 * a head another act is using. Transfer each temporary ownership to
		 * a private RV before the value becomes shared. */
		SvTEMP_off(value);
		for (SSize_t i = PL_tmps_ix; i >= 0; i--) {
			if (PL_tmps_stack[i] != value) continue;
			SV *holder = newSV_type(SVt_IV);
			sv_setrv_noinc(holder, value);
			SvTEMP_on(holder);
			PL_tmps_stack[i] = holder;
		}
	}
	if (SvTYPE(value) == SVt_PVHV)
		Perl_wump_hv_publish_cursor(aTHX_ (HV *)value);
	if (work->used == work->capacity) {
		size_t capacity = work->capacity ? work->capacity * 2 : 32;
		if (capacity < work->capacity || capacity > SIZE_MAX / sizeof(SV *))
			croak("Wump: publication graph is too large");
		Renew(work->values, capacity, SV *);
		work->capacity = capacity;
	}
	if (!mg) {
		Perl_wump_memory_mark(aTHX_ value, 0);
		mg = sv_magicext(value, NULL, PERL_MAGIC_ext, &wump_publish_vtbl, NULL, 0);
		mg->mg_flags |= MGf_COPY | MGf_LOCAL;
	}
	work->values[work->used++] = SvREFCNT_inc(value);
	mg->mg_private = WUMP_PUBLISH_PENDING;
	Perl_wump_memory_mark(aTHX_ value, WUMP_PUBLISH_PENDING);
}

static void wump_publish_visit(pTHX_ SV *value, void *arg) {
	wump_publish_queue(aTHX_ (wump_publish_work *)arg, value);
}

static void wump_publish_edges(pTHX_ wump_publish_work *work, SV *value) {
	if (SvROK(value)) wump_publish_queue(aTHX_ work, SvRV(value));
	if (SvTYPE(value) == SVt_PVAV) {
		AV *av = (AV *)value;
		for (SSize_t i = 0; i <= AvFILLp(av); i++)
			wump_publish_queue(aTHX_ work, AvARRAY(av)[i]);
	} else if (SvTYPE(value) == SVt_PVHV) {
		HV *hv = (HV *)value;
		/* Stashes are global boundaries, not user data graphs. */
		if (!HvNAME_HEK(hv) && HvARRAY(hv)) {
			for (STRLEN i = 0; i <= HvMAX(hv); i++) {
				for (HE *he = HvARRAY(hv)[i]; he; he = HeNEXT(he))
					wump_publish_queue(aTHX_ work, HeVAL(he));
			}
		}
	} else if (SvTYPE(value) == SVt_PVLV) {
		/* These are the same owned target edges released by sv_clear. Tied
		 * T/t delegates instead carry an HE or a fake SV**, never an SV*. */
		if (LvTYPE(value) != 'T' && LvTYPE(value) != 't')
			wump_publish_queue(aTHX_ work, LvTARG(value));
	} else if (SvTYPE(value) == SVt_PVOBJ) {
		for (SSize_t i = 0; i <= ObjectMAXFIELD(value); i++)
			wump_publish_queue(aTHX_ work, ObjectFIELDS(value)[i]);
	} else if (SvTYPE(value) == SVt_PVCV && CvISXSUB((CV *)value)) {
		/* Only these flags certify that the ANY union contains an owned SV.
		 * Other XSUB payloads may be arbitrary pointers or integers. */
		CV *cv = (CV *)value;
		if (CvCONST(cv)) wump_publish_queue(aTHX_ work, (SV *)CvXSUBANY(cv).any_ptr);
		else if (CvREFCOUNTED_ANYSV(cv)) wump_publish_queue(aTHX_ work, CvXSUBANY(cv).any_sv);
	} else if (SvTYPE(value) == SVt_PVCV) {
		/* Use the original pad, rather than an act's private call frame.
		 * Captured/state and constant cells are shared; ordinary locals are not. */
		PADLIST *pads = ((XPVCV *)SvANY(value))->xcv_padlist_u.xcv_padlist;
		if (pads && PadlistMAX(pads) >= 1 && PadlistARRAY(pads)[1]) {
			PAD *pad = PadlistARRAY(pads)[1];
			PADNAMELIST *names = PadlistNAMES(pads);
			for (SSize_t i = 1; i <= AvFILLp(pad); i++) {
				PADNAME *name = i <= PadnamelistMAX(names) ? PadnamelistARRAY(names)[i] : NULL;
				SV *cell = AvARRAY(pad)[i];
				if ((name && (PadnameOUTER(name) || PadnameIsSTATE(name)
					|| (!PadnameLEN(name) && PadnamePV(name))))
					|| (cell && SvTYPE(cell) == SVt_PVCV))
					wump_publish_queue(aTHX_ work, cell);
			}
		}
	}
	if (isREGEXP(value))
		Perl_wump_regex_roots(aTHX_ (REGEXP *)value, wump_publish_visit, work);
	/* A tie object or native cache is reachable through its owner even if
	 * its contents are hidden from ordinary AV/HV storage. */
	if (SvTYPE(value) >= SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if ((mg->mg_flags & MGf_REFCOUNTED) && mg->mg_obj)
				wump_publish_queue(aTHX_ work, mg->mg_obj);
		}
	}
}

static void wump_publish_finish(pTHX_ void *arg) {
	wump_publish_work *work = arg;
	for (size_t i = 0; i < work->used; i++) {
		MAGIC *mg = wump_publish_marker(work->values[i]);
		assert(mg && mg->mg_private == WUMP_PUBLISH_PENDING);
		mg->mg_private = work->complete ? WUMP_PUBLISH_SHARED : 0;
		Perl_wump_memory_mark(aTHX_ work->values[i], work->complete ? WUMP_PUBLISH_SHARED : 0);
	}
	/* Reset suppression and release the mutex before dropping temporary
	 * roots: their final drops can execute Perl destructors. */
	if (work->locked) {
		wump_publisher = work->previous;
		Perl_wump_memory_unlock(aTHX);
	}
	for (size_t i = 0; i < work->used; i++) SvREFCNT_dec(work->values[i]);
	Safefree(work->values);
}

void Perl_wump_publish(pTHX_ SV *value) {
	if (Perl_wump_publish_active(aTHX) || PL_phase == PERL_PHASE_DESTRUCT || !value)
		return;
	/* Completed publications already stop at this head. Check the registry
	 * and active writer before constructing an empty graph walk, without
	 * reading flags or magic which another act may be mutating. */
	if (wump_memory_published(aTHX_ value)) return;
	I32 mark = PL_savestack_ix;
	wump_publish_work work = {0};
	SAVEDESTRUCTOR_X(wump_publish_finish, &work);
	Perl_wump_memory_lock(aTHX);
	work.locked = TRUE;
	work.previous = wump_publisher;
	wump_publisher = aTHX;
	wump_publish_queue(aTHX_ &work, value);
	for (size_t i = 0; i < work.used; i++)
		wump_publish_edges(aTHX_ &work, work.values[i]);
	work.complete = TRUE;
	LEAVE_SCOPE(mark);
}

void Perl_wump_publish_store(pTHX_ SV *owner, SV *value) {
	/* Namespace globs are implicitly shared once acts can run. Before the
	 * first activation, treating ordinary symbol replacement as an escape
	 * upgrades constant values merely to attach publication magic. Native
	 * constant folding and B inspection must keep their original layout.
	 * Explicitly published scalar/container owners still propagate stores. */
	if (!S_wump_context_seen(aTHX) && owner && isGV_with_GP(owner)) return;
	if (owner && SvTYPE(owner) == SVt_PVHV && HvNAME_HEK((HV *)owner)) return;
	if (!Perl_wump_publish_active(aTHX) && Perl_wump_is_shared(aTHX_ owner))
		Perl_wump_publish(aTHX_ value);
}

void Perl_wump_publish_reference(pTHX_ SV *owner, SV *value) {
	if (value && SvROK(value)) Perl_wump_publish_store(aTHX_ owner, SvRV(value));
}

void Perl_wump_publish_snapshot(pTHX_ SV *value) {
	if (!value) return;
	if (SvROK(value)) Perl_wump_publish(aTHX_ SvRV(value));
	else if (SvTYPE(value) == SVt_PVAV) {
		AV *av = (AV *)value;
		for (SSize_t i = 0; i <= AvFILLp(av); i++)
			Perl_wump_publish_snapshot(aTHX_ AvARRAY(av)[i]);
	} else if (SvTYPE(value) == SVt_PVHV) {
		HV *hv = (HV *)value;
		if (HvARRAY(hv)) for (STRLEN i = 0; i <= HvMAX(hv); i++)
			for (HE *he = HvARRAY(hv)[i]; he; he = HeNEXT(he))
				Perl_wump_publish_snapshot(aTHX_ HeVAL(he));
	}
}

static int wump_publish_set(pTHX_ SV *value, MAGIC *mg) {
	PERL_UNUSED_ARG(mg);
	if (Perl_wump_publish_active(aTHX)
		|| PL_phase == PERL_PHASE_DESTRUCT)
		return 0;
	if (!Perl_wump_is_shared(aTHX_ value)) return 0;
	/* Rescan immediate outgoing edges after bulk mutation; already shared
	 * subgraphs stop at their markers. The owner stays shared throughout. */
	I32 mark = PL_savestack_ix;
	wump_publish_work work = {0};
	SAVEDESTRUCTOR_X(wump_publish_finish, &work);
	Perl_wump_memory_lock(aTHX);
	work.locked = TRUE;
	work.previous = wump_publisher;
	wump_publisher = aTHX;
	Perl_wump_memory_check(aTHX_ value);
	wump_publish_edges(aTHX_ &work, value);
	for (size_t i = 0; i < work.used; i++)
		wump_publish_edges(aTHX_ &work, work.values[i]);
	work.complete = TRUE;
	LEAVE_SCOPE(mark);
	return 0;
}

static int wump_publish_copy(pTHX_ SV *value, MAGIC *mg, SV *copy,
	const char *key, I32 length) {
	PERL_UNUSED_ARG(key);
	PERL_UNUSED_ARG(length);
	/* cv_clone copies magic before it installs the captured pad. A new
	 * closure starts unclassified and is walked when it actually escapes. */
	if (SvTYPE(value) == SVt_PVCV) return 0;
	if (mg->mg_private == WUMP_PUBLISH_SHARED)
		Perl_wump_publish_store(aTHX_ value, copy);
	return 0;
}

void Perl_wump_publish_refresh(pTHX_ SV *value) {
	MAGIC *mg = wump_publish_marker(value);
	if (mg) wump_publish_set(aTHX_ value, mg);
}

static int wump_publish_local(pTHX_ SV *value, MAGIC *mg) {
	/* A fresh localization is private until it is explicitly published. */
	PERL_UNUSED_CONTEXT;
	PERL_UNUSED_ARG(value);
	PERL_UNUSED_ARG(mg);
	return 0;
}

static void xs_wump_is_shared(pTHX_ CV *cv) {
	dXSARGS;
	PERL_UNUSED_ARG(cv);
	if (items != 1) croak("Usage: Wump::is_shared(REFERENCE)");
	SvGETMAGIC(ST(0));
	if (!SvROK(ST(0))) croak("Usage: Wump::is_shared(REFERENCE)");
	ST(0) = boolSV(Perl_wump_is_shared(aTHX_ SvRV(ST(0))));
	XSRETURN(1);
}
