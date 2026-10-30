/* Package-slot bindings owned by a task. Included by wump_core.c. */
typedef struct wump_local {
	GV *origin, *anchor;
	SV *value;
	char kind;
	char magic;
	UV sequence;
	bool pocket;
	struct wump_local *next;
} wump_local;

static GV *wump_local_origin(pTHX_ GV *gv) {
	if (gv == PL_defgv) return aTHX->Idefgv;
	if (gv == PL_errgv) return aTHX->Ierrgv;
	if (gv == PL_replgv) return aTHX->Ireplgv;
	return gv;
}

static wump_local *wump_local_find(pTHX_ GV *gv, char kind, bool inherit) {
	struct wump_perl_task *task = PL_wump_task;
	/* No binding can match an empty list. Avoid inspecting shared package
	 * scalars (and taking their metadata lock) on this common lookup path. */
	if (!task || !task->locals) return NULL;
	gv = wump_local_origin(aTHX_ gv);
	GP *gp = GvGP(gv);
	/* These canonical GVs identify private task slots. Their root values
	 * can be changing on the main act (notably the implicit for iterator). */
	bool special = gv == aTHX->Idefgv || gv == aTHX->Ierrgv || gv == aTHX->Ireplgv;
	char magic = kind == 's' && gp && !special ? Perl_wump_magic_kind(aTHX_ gp->gp_sv) : 0;
	for (wump_local *slot = task->locals; slot; slot = slot->next) {
		if (inherit && slot->pocket) continue;
		if (kind == 's' && magic && slot->magic == magic) return slot;
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
	slot->anchor = (GV *)newSV(0);
	gv_init(slot->anchor, NULL, "__wump_local", 12, 0);
	gp_free(slot->anchor);
	GvGP_set(slot->anchor, gp_ref(GvGP(gv)));
	slot->kind = kind;
	slot->value = value;
	slot->sequence = ++task->next_binding;
	slot->next = task->locals;
	task->locals = slot;
	return slot;
}

static void wump_local_check(pTHX_ SV *value, char kind) {
	if (value == NULL) return;
	bool unsafe = SvGMAGICAL(value) || SvSMAGICAL(value);
	if (unsafe) {
		unsafe = FALSE;
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if (Perl_wump_publish_magic(mg)) continue;
			if (mg->mg_virtual && (mg->mg_virtual->svt_get || mg->mg_virtual->svt_set))
				unsafe = TRUE;
		}
	}
	if (kind == 's' && Perl_wump_magic_kind(aTHX_ value)) unsafe = FALSE;
	if (kind != 's' && SvMAGICAL(value)) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if (mg->mg_type != PERL_MAGIC_backref && mg->mg_type != PERL_MAGIC_arylen_p
				&& !Perl_wump_element_magic(mg) && !Perl_wump_publish_magic(mg))
				unsafe = TRUE;
		}
	}
	if (unsafe) {
		croak("Wump: magic variable localization in a task is not supported yet");
	}
}

void Perl_wump_save_capture(pTHX_ GV *gv) {
	/* Internal save_re_context isolates numeric capture cells. Their magic
	 * reads the task's current match; it must remain attached in callbacks.
	 * These transient bindings are excluded from spawn snapshots. */
	SV *old = GvSV(gv);
	SV *value = newSV(0);
	if (SvTYPE(old) >= SVt_PVMG && SvMAGIC(old)) mg_localize(old, value, FALSE);
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task, gv, 's', value);
	slot->pocket = TRUE;
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
}

void Perl_wump_save_defsv(pTHX) {
	/* Regex callbacks and XS use SAVE_DEFSV even for magical subjects.
	 * Preserve their existing SV identity; DEFSV_set supplies the value. */
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task, aTHX->Idefgv, 's', NULL);
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
}

static char wump_native_magic(pTHX_ SV *value) {
	char found = 0;
	if (!value || !SvMAGICAL(value)) return 0;
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
		if (mg->mg_type == PERL_MAGIC_sv && mg->mg_virtual == &PL_vtbl_sv
			&& mg->mg_len == 1 && mg->mg_ptr
			&& (mg->mg_ptr[0] == '!' || mg->mg_ptr[0] == '\005'
				|| mg->mg_ptr[0] == '?' || mg->mg_ptr[0] == '\006' || mg->mg_ptr[0] == '.'))
			found = mg->mg_ptr[0];
		else if (mg->mg_type != PERL_MAGIC_backref && mg->mg_type != PERL_MAGIC_taint
			&& !Perl_wump_publish_magic(mg)) return 0;
	}
	return found;
}

static void wump_errno_restore(pTHX_ void *arg) {
	PERL_UNUSED_CONTEXT;
	errno = PTR2IV(arg);
}

SV *Perl_wump_localize(pTHX_ GV *gv, char kind) {
	SV *old = kind == 's' ? GvSV(gv) : kind == 'a' ? (SV *)GvAV(gv) : (SV *)GvHV(gv);
	/* Numbered captures read the task's current match. Like the regex
	 * engine's internal save_re_context, explicit local needs a fresh
	 * magical cell without treating it as an inheritable ordinary value. */
	MAGIC *capture = kind == 's' && old && SvMAGICAL(old)
		? mg_find(old, PERL_MAGIC_sv) : NULL;
	if (capture && capture->mg_virtual == &PL_vtbl_sv
		&& !capture->mg_ptr && capture->mg_len > 0) {
		Perl_wump_save_capture(aTHX_ gv);
		return GvSV(gv);
	}
	char native_magic = kind == 's' ? wump_native_magic(aTHX_ old) : 0;
	if (native_magic) {
		if (native_magic == '\006' && PL_op && PL_op->op_wump_pocket)
			croak("Wump: pocket descriptor boundary is not supported yet; use local");
		/* Linux $! and $^E read native errno, which the scheduler already
		 * preserves per act. Restore its value, never a native TLS address. */
		int saved = errno;
		SV *value = newSV(0);
		mg_localize(old, value, FALSE);
		wump_local *slot = wump_local_add(aTHX_ PL_wump_task, gv, 's', value);
		slot->pocket = TRUE;
		if (native_magic == '?') {
			SAVEI32(PL_statusvalue);
			SAVEI32(PL_statusvalue_posix);
		} else if (native_magic == '\006') {
			/* Socket libraries localize $^F while opening inheritable handles.
			 * maxsysfd is task state; save its value in this act's scope. */
			SAVEI32(PL_maxsysfd);
		} else if (native_magic != '.') {
			SAVEDESTRUCTOR_X(wump_errno_restore, INT2PTR(void *, (IV)saved));
		}
		SAVEDESTRUCTOR_X(wump_local_pop, slot);
		int localizing = PL_localizing;
		PL_localizing = 1;
		mg_set(value);
		PL_localizing = localizing;
		return value;
	}
	wump_local_check(aTHX_ old, kind);
	char magic = kind == 's' ? Perl_wump_magic_kind(aTHX_ old) : 0;
	SV *value = magic ? Perl_wump_magic_new(aTHX_ magic, NULL)
		: kind == 's' ? newSV(0) : kind == 'a' ? (SV *)newAV() : (SV *)newHV();
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task,
		wump_local_origin(aTHX_ gv), kind, value);
	slot->magic = magic;
	slot->pocket = PL_op && PL_op->op_wump_pocket;
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
	return value;
}

void Perl_wump_local_elements_check(pTHX) {
	if (!PL_wump_task && PL_op->op_wump_pocket)
		croak("Wump: pocket requires a running task");
	if (PL_wump_task && (PL_op->op_private & OPpLVAL_INTRO)
		&& PL_op->op_type == OP_DELETE) {
		croak("Wump: delete localization in a task is not supported yet");
	}
}

static void wump_local_snapshot(pTHX_ struct wump_perl_task *task) {
	if (PL_wump_task == NULL) return;
	/* Validate every inheritable value before copying. Copying must not call
	 * FETCH hooks that can suspend or alter the parent's binding list. */
	for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
		if (wump_local_find(aTHX_ slot->origin, slot->kind, TRUE) == slot)
			Perl_wump_snapshot_check(aTHX_ slot->value, slot->kind);
	}
	for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
		if (wump_local_find(aTHX_ slot->origin, slot->kind, TRUE) != slot) continue;
		SV *copy;
		if (slot->value == NULL) copy = NULL;
		else if (slot->kind == 's') copy = Perl_wump_magic_copy(aTHX_ slot->value);
		else if (slot->kind == 'h') copy = (SV *)Perl_wump_snapshot_hv(aTHX_ (HV *)slot->value);
		else copy = (SV *)Perl_wump_snapshot_av(aTHX_ (AV *)slot->value);
		wump_local *inherited = wump_local_add(aTHX_ task, slot->origin, slot->kind, copy);
		inherited->magic = slot->magic;
		inherited->sequence = slot->sequence;
		if (task->next_binding < slot->sequence) task->next_binding = slot->sequence;
	}
	Perl_wump_elements_snapshot(aTHX_ task);
}
