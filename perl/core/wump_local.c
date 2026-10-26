/* Package-slot bindings owned by a task. Included by wump_core.c. */
typedef struct wump_local {
	GV *origin, *anchor;
	SV *value;
	char kind;
	struct wump_local *next;
} wump_local;

static GV *wump_local_origin(pTHX_ GV *gv) {
	if (gv == PL_defgv) return aTHX->Idefgv;
	if (gv == PL_errgv) return aTHX->Ierrgv;
	if (gv == PL_replgv) return aTHX->Ireplgv;
	return gv;
}

static wump_local *wump_local_find(pTHX_ GV *gv, char kind) {
	if (PL_wump_task == NULL) return NULL;
	gv = wump_local_origin(aTHX_ gv);
	for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
		if (slot->kind == kind && GvGP(slot->anchor) == GvGP(gv)) return slot;
	}
	return NULL;
}

static void wump_local_drop(pTHX_ wump_local **head) {
	wump_local *slot = *head;
	*head = slot->next;
	SV *value = slot->value;
	/* Detach first: DESTROY sees the enclosing binding and may spawn.
	 * Save these roots so even a throwing destructor releases them. */
	SAVEFREESV(slot->anchor);
	SAVEFREESV(slot->origin);
	Safefree(slot);
	SvREFCNT_dec(value);
}

static void wump_local_pop(pTHX_ void *arg) {
	assert(PL_wump_task->locals == (wump_local *)arg);
	PERL_UNUSED_ARG(arg);
	wump_local_drop(aTHX_ &PL_wump_task->locals);
}

static void wump_local_clear(pTHX_ struct wump_perl_task *task) {
	Perl_wump_elements_clear(aTHX_ task);
	I32 mark = PL_savestack_ix;
	while (task->locals != NULL) wump_local_drop(aTHX_ &task->locals);
	LEAVE_SCOPE(mark);
}

static wump_local *wump_local_add(pTHX_ struct wump_perl_task *task,
	GV *gv, char kind, SV *value) {
	wump_local *slot;
	Newxz(slot, 1, wump_local);
	slot->origin = (GV *)SvREFCNT_inc(gv);
	/* Hold the GP independently of symbol-table alias replacement. */
	slot->anchor = (GV *)newSV_type(SVt_PVGV);
	gv_init(slot->anchor, PL_defstash, "__wump_local", 12, 0);
	gp_free(slot->anchor);
	GvGP_set(slot->anchor, gp_ref(GvGP(gv)));
	slot->kind = kind;
	slot->value = value;
	slot->next = task->locals;
	task->locals = slot;
	return slot;
}

static void wump_local_check(pTHX_ SV *value, char kind) {
	if (value == NULL) return;
	bool unsafe = SvGMAGICAL(value) || SvSMAGICAL(value);
	if (kind != 's' && SvMAGICAL(value)) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if (mg->mg_type != PERL_MAGIC_backref && mg->mg_type != PERL_MAGIC_arylen_p
				&& !Perl_wump_element_magic(mg))
				unsafe = TRUE;
		}
	}
	if (unsafe) {
		croak("Wump: magic variable localization in a task is not supported yet");
	}
}

void Perl_wump_save_defsv(pTHX) {
	/* Regex callbacks and XS use SAVE_DEFSV even for magical subjects.
	 * Preserve their existing SV identity; DEFSV_set supplies the value. */
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task, aTHX->Idefgv, 's', NULL);
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
}

SV *Perl_wump_localize(pTHX_ GV *gv, char kind) {
	SV *old = kind == 's' ? GvSV(gv) : kind == 'a' ? (SV *)GvAV(gv) : (SV *)GvHV(gv);
	wump_local_check(aTHX_ old, kind);
	SV *value = kind == 's' ? newSV(0) : kind == 'a' ? (SV *)newAV() : (SV *)newHV();
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task,
		wump_local_origin(aTHX_ gv), kind, value);
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
	return value;
}

void Perl_wump_local_elements_check(pTHX) {
	if (PL_wump_task && (PL_op->op_private & OPpLVAL_INTRO)
		&& PL_op->op_type == OP_DELETE) {
		croak("Wump: delete localization in a task is not supported yet");
	}
}

static void wump_local_snapshot_check(pTHX_ wump_local *slot) {
	wump_local_check(aTHX_ slot->value, slot->kind);
	if (slot->value == NULL) return;
	if (slot->kind == 'a') {
		AV *av = (AV *)slot->value;
		for (SSize_t i = 0; i <= AvFILL(av); i++) {
			SV **item = av_fetch(av, i, 0);
			if (item) wump_local_check(aTHX_ *item, 's');
		}
	} else if (slot->kind == 'h' && HvARRAY((HV *)slot->value)) {
		HV *hv = (HV *)slot->value;
		for (STRLEN i = 0; i <= HvMAX(hv); i++) {
			for (HE *he = HvARRAY(hv)[i]; he; he = HeNEXT(he)) {
				wump_local_check(aTHX_ HeVAL(he), 's');
			}
		}
	}
}

static void wump_local_snapshot(pTHX_ struct wump_perl_task *task) {
	if (PL_wump_task == NULL) return;
	/* Validate every visible value before copying. Copying must not call
	 * FETCH hooks that can suspend or alter the parent's binding list. */
	for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
		if (wump_local_find(aTHX_ slot->origin, slot->kind) == slot)
			wump_local_snapshot_check(aTHX_ slot);
	}
	for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
		if (wump_local_find(aTHX_ slot->origin, slot->kind) != slot) continue;
		SV *copy;
		if (slot->value == NULL) copy = NULL;
		else if (slot->kind == 's') copy = newSVsv(slot->value);
		else if (slot->kind == 'h') copy = (SV *)newHVhv((HV *)slot->value);
		else {
			AV *source = (AV *)slot->value, *av = newAV();
			SSize_t end = AvFILL(source);
			av_extend(av, end);
			for (SSize_t i = 0; i <= end; i++) {
				SV **item = av_fetch(source, i, 0);
				if (item) av_store(av, i, newSVsv(*item));
			}
			AvFILLp(av) = end;
			copy = (SV *)av;
		}
		wump_local_add(aTHX_ task, slot->origin, slot->kind, copy);
	}
	Perl_wump_elements_snapshot(aTHX_ task);
}
