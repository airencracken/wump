/* Element overlays never replace the shared AV/HV or its original cells.
 * Array markers disable upstream's direct-pointer fast paths. */
typedef struct wump_element {
	SV *origin;
	SV *value;
	HV *cell;
	SSize_t index;
	bool present;
	bool pocket;
	char hook;
	UV sequence;
	struct wump_element *next;
} wump_element;

typedef struct wump_element_iter {
	HV *origin, *view;
	STRLEN bucket;
	U32 random;
	bool cursor;
	struct wump_element_iter *next;
} wump_element_iter;

static const MGVTBL wump_element_vtbl = {0};

bool Perl_wump_element_magic(const MAGIC *mg) {
	return mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == &wump_element_vtbl;
}

static bool wump_element_has(pTHX_ const SV *origin) {
	if (!PL_wump_task) return FALSE;
	for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
		if (slot->origin == origin) return TRUE;
	}
	return FALSE;
}

static wump_element *wump_element_av(pTHX_ AV *av, SSize_t index, bool inherit) {
	if (!PL_wump_task) return NULL;
	for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
		if (inherit && slot->pocket) continue;
		if (slot->origin == (SV *)av && slot->index == index) return slot;
	}
	return NULL;
}

static wump_element *wump_element_hv(pTHX_ HV *hv, const char *key,
	STRLEN len, int flags, bool inherit) {
	if (!PL_wump_task) return NULL;
	for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
		if (inherit && slot->pocket) continue;
		if (slot->origin == (SV *)hv && hv_common(slot->cell, NULL, key, len,
			flags & HVhek_UTF8, HV_FETCH_ISEXISTS, NULL, 0)) return slot;
	}
	return NULL;
}

static SSize_t wump_element_fill(pTHX_ AV *av, bool inherit) {
	SSize_t fill = SvRMAGICAL(av) ? mg_size((SV *)av) : AvFILLp(av);
	if (PL_wump_task) {
		for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
			if (inherit && slot->pocket) continue;
			if (slot->origin == (SV *)av && slot->index > fill) fill = slot->index;
		}
	}
	return fill;
}

SSize_t Perl_wump_av_fill(AV *av) {
	dTHX;
	return wump_element_fill(aTHX_ av, FALSE);
}

SV **Perl_wump_av_slot(pTHX_ AV *av, SSize_t *index, bool lval, bool *handled) {
	*handled = FALSE;
	if (!wump_element_has(aTHX_ (SV *)av)) return NULL;
	if (*index < 0) *index += Perl_wump_av_fill(av) + 1;
	if (*index < 0) { *handled = TRUE; return NULL; }
	wump_element *slot = wump_element_av(aTHX_ av, *index, FALSE);
	if (!slot) return NULL;
	*handled = TRUE;
	if (!slot->present || !slot->value) {
		if (!lval) return NULL;
		slot->present = TRUE;
		slot->value = newSV(0);
	}
	return &slot->value;
}

void Perl_wump_element_structure(pTHX_ SV *aggregate) {
	if (wump_element_has(aTHX_ aggregate))
		croak("Wump: structural mutation with active element bindings is not supported yet");
}

static void wump_element_mark(pTHX_ SV *origin) {
	if (!mg_findext(origin, PERL_MAGIC_ext, &wump_element_vtbl))
		sv_magicext(origin, NULL, PERL_MAGIC_ext, &wump_element_vtbl, NULL, 0);
}

static void wump_element_invalidate(pTHX_ struct wump_perl_task *task, SV *origin) {
	wump_element_iter **link = &task->element_iters;
	while (*link) {
		wump_element_iter *iter = *link;
		if ((SV *)iter->origin != origin) { link = &iter->next; continue; }
		*link = iter->next;
		HV *view = iter->view, *owner = iter->origin;
		bool cursor = iter->cursor;
		Safefree(iter);
		SvREFCNT_dec(view);
		/* A weak dereference can leave the cursor as the only owner. Keep
		 * that pin through the rest of the current opcode/native temp scope. */
		if (cursor) {
			/* newRV_noinc clears the referent's TEMP flag even when it is
			 * already clear. Use the setter, which only writes the new RV. */
			SV *pin = newSV_type(SVt_IV);
			sv_setrv_noinc(pin, (SV *)owner);
			sv_2mortal(pin);
		} else SvREFCNT_dec(owner);
		return;
	}
}

static void wump_element_invalidate_view(pTHX_ struct wump_perl_task *task, SV *origin) {
	for (wump_element_iter *iter = task->element_iters; iter; iter = iter->next) {
		if ((SV *)iter->origin != origin) continue;
		if (!iter->cursor) wump_element_invalidate(aTHX_ task, origin);
		return;
	}
}

static void wump_element_drop(pTHX_ struct wump_perl_task *task) {
	wump_element *slot = task->elements;
	task->elements = slot->next;
	SV *value = slot->value;
	HV *cell = slot->cell;
	SV *origin = slot->origin;
	SAVEFREESV(slot->origin);
	Safefree(slot);
	wump_element_invalidate(aTHX_ task, origin);
	SvREFCNT_dec(value);
	SvREFCNT_dec(cell);
}

static void wump_element_pop(pTHX_ void *arg) {
	assert(PL_wump_task->elements == (wump_element *)arg);
	PERL_UNUSED_ARG(arg);
	wump_element_drop(aTHX_ PL_wump_task);
}

static wump_element *wump_element_add(pTHX_ struct wump_perl_task *task, SV *origin) {
	wump_element *slot;
	Newxz(slot, 1, wump_element);
	slot->origin = SvREFCNT_inc(origin);
	slot->present = TRUE;
	slot->sequence = ++task->next_binding;
	slot->next = task->elements;
	task->elements = slot;
	return slot;
}

SV **Perl_wump_local_av(pTHX_ AV *av, SSize_t index) {
	wump_local_check(aTHX_ (SV *)av, 'a');
	if (SvREADONLY(av)) croak("Wump: cannot localize an element of a read-only array");
	if (index < 0) index += Perl_wump_av_fill(av) + 1;
	if (index < 0) croak("Wump: array index outside the localized view");
	MEM_WRAP_CHECK_s(index, SV *, "Out of memory during array localization");
	SV **old = av_fetch(av, index, 0);
	if (old) wump_local_check(aTHX_ *old, 's');
	wump_element_mark(aTHX_ (SV *)av);
	wump_element *slot = wump_element_add(aTHX_ PL_wump_task, (SV *)av);
	slot->pocket = PL_op->op_wump_pocket;
	slot->index = index;
	slot->value = newSV(0);
	SAVEDESTRUCTOR_X(wump_element_pop, slot);
	return &slot->value;
}

HE *Perl_wump_local_hv(pTHX_ HV *hv, SV *key) {
	if (SvREADONLY(hv) || HvNAME_HEK(hv))
		croak("Wump: cannot localize an element of a restricted hash or symbol table");
	/* Canonicalize once, including overloaded/magical key conversion. */
	STRLEN len;
	const char *bytes = SvPV_const(key, len);
	SV *name = sv_2mortal(newSVpvn_flags(bytes, len, SvUTF8(key) ? SVf_UTF8 : 0));
	char hook = Perl_wump_hook_kind(aTHX_ hv, name);
	if (!hook) wump_local_check(aTHX_ (SV *)hv, 'h');
	HE *old = hv_fetch_ent(hv, name, 0, 0);
	if (old) wump_local_check(aTHX_ HeVAL(old), 's');
	wump_element_mark(aTHX_ (SV *)hv);
	wump_element_invalidate(aTHX_ PL_wump_task, (SV *)hv);
	wump_element *slot = wump_element_add(aTHX_ PL_wump_task, (SV *)hv);
	slot->pocket = PL_op->op_wump_pocket;
	slot->hook = hook;
	slot->cell = newHV();
	HE *entry = hv_store_ent(slot->cell, name,
		hook ? Perl_wump_magic_new(aTHX_ hook, NULL) : newSV(0), 0);
	SAVEDESTRUCTOR_X(wump_element_pop, slot);
	return entry;
}

bool Perl_wump_hv_slot(pTHX_ HV *hv, const char *key, STRLEN len, int flags,
	int action, SV *value, U32 hash, void **result) {
	if (PL_wump_task && (action & (HV_FETCH_ISSTORE | HV_DELETE)))
		wump_element_invalidate_view(aTHX_ PL_wump_task, (SV *)hv);
	wump_element *slot = wump_element_hv(aTHX_ hv, key, len, flags, FALSE);
	if (!slot) {
		if (action & HV_FETCH_ISSTORE) Perl_wump_publish_store(aTHX_ (SV *)hv, value);
		return FALSE;
	}
	if (action & HV_DELETE) {
		hv_iterinit(slot->cell);
		HE *he = hv_iternext(slot->cell); /* single immutable key */
		SV *old = HeVAL(he);
		bool existed = slot->present;
		HeVAL(he) = slot->hook ? Perl_wump_magic_new(aTHX_ slot->hook, NULL) : newSV(0);
		slot->present = FALSE;
		if (flags & HVhek_FREEKEY) Safefree(key);
		if (existed && !(action & G_DISCARD)) *result = sv_2mortal(old);
		else { SvREFCNT_dec(old); *result = NULL; }
		return TRUE;
	}
	bool writing = action & (HV_FETCH_LVALUE | HV_FETCH_ISSTORE);
	if (!slot->present && !writing) {
		if (flags & HVhek_FREEKEY) Safefree(key);
		*result = NULL;
		return TRUE;
	}
	if (slot->hook && (action & HV_FETCH_ISSTORE)) {
		if (!value) croak("Wump: null hook-cell replacement is unsupported");
		Perl_wump_hook_store(aTHX_ value, slot->hook);
	}
	if (writing) slot->present = TRUE;
	*result = hv_common(slot->cell, NULL, key, len, flags, action, value, hash);
	return TRUE;
}

static HV *wump_element_view(pTHX_ HV *hv, bool inherit) {
	HV *view = newHV();
	/* Raw buckets avoid disturbing either the base or another task iterator. */
	if (HvARRAY(hv)) {
		for (STRLEN i = 0; i <= HvMAX(hv); i++) {
			for (HE *he = HvARRAY(hv)[i]; he; he = HeNEXT(he)) {
				if (HeVAL(he) == &PL_sv_placeholder) continue;
				hv_store_ent(view, hv_iterkeysv(he), SvREFCNT_inc(HeVAL(he)), 0);
			}
		}
	}
	for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
		if (slot->origin != (SV *)hv) continue;
		if (inherit && slot->pocket) continue;
		hv_iterinit(slot->cell);
		HE *he = hv_iternext(slot->cell);
		SV *key = hv_iterkeysv(he);
		STRLEN len;
		const char *bytes = SvPV_const(key, len);
		if (wump_element_hv(aTHX_ hv, bytes, len, SvUTF8(key) ? HVhek_UTF8 : 0, inherit) != slot)
			continue;
		if (slot->present) hv_store_ent(view, key, SvREFCNT_inc(HeVAL(he)), 0);
		else hv_delete_ent(view, key, G_DISCARD, 0);
	}
	return view;
}

STRLEN Perl_wump_hv_used(HV *hv) {
	dTHX;
	if (!wump_element_has(aTHX_ (SV *)hv)) return HvTOTALKEYS(hv) - HvPLACEHOLDERS_get(hv);
	HV *view = wump_element_view(aTHX_ hv, FALSE);
	STRLEN count = HvTOTALKEYS(view);
	SvREFCNT_dec(view);
	return count;
}

static bool wump_hv_plain(pTHX_ HV *hv) {
	if (!PL_wump_task || !hv || SvTYPE(hv) != SVt_PVHV
		|| HvNAME_HEK(hv) || PL_phase == PERL_PHASE_DESTRUCT
		|| wump_element_has(aTHX_ (SV *)hv)) return FALSE;
	for (MAGIC *mg = SvMAGIC(hv); mg; mg = mg->mg_moremagic) {
		if (!Perl_wump_publish_magic(mg) && !Perl_wump_element_magic(mg)
			&& mg->mg_type != PERL_MAGIC_backref) return FALSE;
	}
	return TRUE;
}

bool Perl_wump_hv_readable(pTHX_ HV *hv) {
	return wump_hv_plain(aTHX_ hv) && Perl_wump_is_shared(aTHX_ (SV *)hv);
}

bool Perl_wump_hv_iter_reset(pTHX_ HV *hv, I32 *count) {
	if (!Perl_wump_hv_readable(aTHX_ hv)) return FALSE;
	/* Match hv_iterinit's native count, which includes placeholders. */
	*count = HvTOTALKEYS(hv);
	wump_element_invalidate(aTHX_ PL_wump_task, (SV *)hv);
	return TRUE;
}

static wump_element_iter *wump_hv_cursor(pTHX_ HV *hv) {
	wump_element_iter *iter;
	for (iter = PL_wump_task->element_iters; iter; iter = iter->next)
		if (iter->origin == hv) break;
	if (!iter) {
		Newxz(iter, 1, wump_element_iter);
		iter->origin = (HV *)SvREFCNT_inc(hv);
		iter->view = newHV(); /* Keys visited by this act; no value snapshots. */
		iter->cursor = TRUE;
#ifdef PERL_HASH_RANDOMIZE_KEYS
		iter->random = HvRAND_get(hv);
#endif
		iter->next = PL_wump_task->element_iters;
		PL_wump_task->element_iters = iter;
	}
	assert(iter->cursor);
	return iter;
}

static void wump_hv_visit(pTHX_ wump_element_iter *iter, HE *entry) {
	hv_common(iter->view, NULL, HeKEY(entry), HeKLEN(entry),
		HeKUTF8(entry) ? HVhek_UTF8 : 0, HV_FETCH_ISSTORE,
		SvREFCNT_inc(&PL_sv_yes), HeHASH(entry));
}

void Perl_wump_hv_publish_cursor(pTHX_ HV *hv) {
	if (!wump_hv_plain(aTHX_ hv) || PL_wump_task->finished
		|| !HvHasAUX(hv) || !HvEITER_get(hv) || HvRITER_get(hv) < 0
		|| (STRLEN)HvRITER_get(hv) > HvMAX(hv)) return;
	/* Publication switches the parent from its root cursor to private state.
	 * Children get no record and begin at the start. Native root execution
	 * outside scheduling keeps its own untouched cursor. */
	wump_element_iter *iter = wump_hv_cursor(aTHX_ hv);
	iter->bucket = HvRITER_get(hv);
	HE *next = HeNEXT(HvEITER_get(hv));
	for (STRLEN position = 0; position <= iter->bucket; position++) {
		STRLEN bucket = (position ^ iter->random) & HvMAX(hv);
		HE *stop = position == iter->bucket ? next : NULL;
		for (HE *entry = HvARRAY(hv)[bucket]; entry && entry != stop; entry = HeNEXT(entry))
			wump_hv_visit(aTHX_ iter, entry);
	}
}

HE *Perl_wump_hv_iter_next(pTHX_ HV *hv, I32 flags, bool *handled) {
	*handled = Perl_wump_hv_readable(aTHX_ hv);
	if (!*handled) return NULL;
	if (!HvARRAY(hv) || !HvTOTALKEYS(hv)) {
		wump_element_invalidate(aTHX_ PL_wump_task, (SV *)hv);
		return NULL;
	}
	wump_element_iter *iter = wump_hv_cursor(aTHX_ hv);
	/* Rescan only the current collision chain. Remember keys, never HE
	 * pointers: same-act deletes can free the last or next returned entry.
	 * Insertions/resizing during each retain Perl's unspecified semantics. */
	while (iter->bucket <= HvMAX(hv)) {
		STRLEN bucket = (iter->bucket ^ iter->random) & HvMAX(hv);
		for (HE *entry = HvARRAY(hv)[bucket]; entry; entry = HeNEXT(entry)) {
			if (!(flags & HV_ITERNEXT_WANTPLACEHOLDERS)
				&& HeVAL(entry) == &PL_sv_placeholder) continue;
			int key_flags = HeKUTF8(entry) ? HVhek_UTF8 : 0;
			if (hv_common(iter->view, NULL, HeKEY(entry), HeKLEN(entry), key_flags,
				HV_FETCH_ISEXISTS, NULL, HeHASH(entry))) continue;
			wump_hv_visit(aTHX_ iter, entry);
			return entry;
		}
		iter->bucket++;
	}
	wump_element_invalidate(aTHX_ PL_wump_task, (SV *)hv);
	return NULL;
}

HV *Perl_wump_hv_iteration(pTHX_ HV *hv, bool reset) {
	if (!wump_element_has(aTHX_ (SV *)hv)) return hv;
	wump_element_iter *iter;
	for (iter = PL_wump_task->element_iters; iter; iter = iter->next) {
		if (iter->origin == hv) break;
	}
	if (!iter) {
		Newxz(iter, 1, wump_element_iter);
		iter->origin = (HV *)SvREFCNT_inc(hv);
		iter->next = PL_wump_task->element_iters;
		PL_wump_task->element_iters = iter;
	}
	if (reset || !iter->view || (HvRITER(iter->view) == -1 && !HvEITER(iter->view))) {
		HV *old = iter->view;
		iter->view = wump_element_view(aTHX_ hv, FALSE);
		hv_iterinit(iter->view);
		SvREFCNT_dec(old);
	}
	return iter->view;
}

HV *Perl_wump_hv_clone(pTHX_ HV *hv) {
	if (!hv || !wump_element_has(aTHX_ (SV *)hv)) return NULL;
	HV *view = wump_element_view(aTHX_ hv, FALSE);
	HV *copy = newHVhv(view);
	SvREFCNT_dec(view);
	return copy;
}

void Perl_wump_elements_clear(pTHX_ struct wump_perl_task *task) {
	I32 mark = PL_savestack_ix;
	while (task->elements) wump_element_drop(aTHX_ task);
	while (task->element_iters) {
		wump_element_iter *iter = task->element_iters;
		task->element_iters = iter->next;
		HV *view = iter->view, *origin = iter->origin;
		Safefree(iter);
		SvREFCNT_dec(view);
		SvREFCNT_dec(origin);
	}
	LEAVE_SCOPE(mark);
}

static bool wump_element_inheritable(pTHX_ wump_element *slot) {
	if (slot->pocket) return FALSE;
	if (!slot->cell) return wump_element_av(aTHX_ (AV *)slot->origin, slot->index, TRUE) == slot;
	hv_iterinit(slot->cell);
	SV *key = hv_iterkeysv(hv_iternext(slot->cell));
	STRLEN len;
	const char *bytes = SvPV_const(key, len);
	return wump_element_hv(aTHX_ (HV *)slot->origin, bytes, len,
		SvUTF8(key) ? HVhek_UTF8 : 0, TRUE) == slot;
}

static SV *wump_snapshot_array_value(pTHX_ AV *av, SSize_t index) {
	wump_element *slot = wump_element_av(aTHX_ av, index, TRUE);
	if (slot) return slot->present ? slot->value : NULL;
	return index <= AvFILLp(av) ? AvARRAY(av)[index] : NULL;
}

void Perl_wump_snapshot_check(pTHX_ SV *value, char kind) {
	wump_local_check(aTHX_ value, kind);
	if (!value || kind == 's') return;
	if (kind == 'a') {
		AV *source = (AV *)value;
		SSize_t end = wump_element_fill(aTHX_ source, TRUE);
		for (SSize_t i = 0; i <= end; i++)
			wump_local_check(aTHX_ wump_snapshot_array_value(aTHX_ source, i), 's');
	} else {
		I32 mark = PL_savestack_ix;
		HV *view = wump_element_view(aTHX_ (HV *)value, TRUE);
		SAVEFREESV(view);
		hv_iterinit(view);
		HE *he;
		while ((he = hv_iternext(view))) wump_local_check(aTHX_ HeVAL(he), 's');
		LEAVE_SCOPE(mark);
	}
}

AV *Perl_wump_snapshot_av(pTHX_ AV *source) {
	Perl_wump_snapshot_check(aTHX_ (SV *)source, 'a');
	AV *copy = newAV();
	SSize_t end = wump_element_fill(aTHX_ source, TRUE);
	av_extend(copy, end);
	for (SSize_t i = 0; i <= end; i++) {
		SV *value = wump_snapshot_array_value(aTHX_ source, i);
		if (value) av_store(copy, i, newSVsv(value));
	}
	AvFILLp(copy) = end;
	return copy;
}

HV *Perl_wump_snapshot_hv(pTHX_ HV *source) {
	Perl_wump_snapshot_check(aTHX_ (SV *)source, 'h');
	I32 mark = PL_savestack_ix;
	HV *view = wump_element_view(aTHX_ source, TRUE);
	SAVEFREESV(view);
	HV *copy = newHVhv(view);
	LEAVE_SCOPE(mark);
	return copy;
}

void Perl_wump_elements_snapshot(pTHX_ struct wump_perl_task *task) {
	/* Validate before copying, so FETCH cannot mutate a live binding list. */
	for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
		if (!wump_element_inheritable(aTHX_ slot)) continue;
		if (slot->cell) {
			hv_iterinit(slot->cell);
			wump_local_check(aTHX_ HeVAL(hv_iternext(slot->cell)), 's');
		} else wump_local_check(aTHX_ slot->value, 's');
	}
	for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
		if (!wump_element_inheritable(aTHX_ slot)) continue;
		wump_element *copy = wump_element_add(aTHX_ task, slot->origin);
		copy->index = slot->index;
		copy->present = slot->present;
		copy->hook = slot->hook;
		copy->sequence = slot->sequence;
		if (task->next_binding < slot->sequence) task->next_binding = slot->sequence;
		if (slot->hook) {
			hv_iterinit(slot->cell);
			HE *he = hv_iternext(slot->cell);
			copy->cell = newHV();
			hv_store_ent(copy->cell, hv_iterkeysv(he), Perl_wump_magic_copy(aTHX_ HeVAL(he)), 0);
		} else if (slot->cell) copy->cell = newHVhv(slot->cell);
		else copy->value = slot->value ? newSVsv(slot->value) : NULL;
	}
	/* Keep the parent's precedence order without retaining hidden scopes. */
	wump_element *reversed = NULL;
	while (task->elements) {
		wump_element *slot = task->elements;
		task->elements = slot->next;
		slot->next = reversed;
		reversed = slot;
	}
	task->elements = reversed;
}
