/* Runtime settings belong to their scalar cells, including escaped references.
 * A hidden AV supplies stable pointer storage and owns each cache;
 * ordinary magic-object refcounting/cloning handles its lifetime. */
static int wump_magic_local(pTHX_ SV *value, MAGIC *source);
static const MGVTBL wump_magic_vtbl = { .svt_local = wump_magic_local };

static SV *wump_magic_copy_cache(pTHX_ SV *value) {
	if (value == PERL_WARNHOOK_FATAL) return SvREFCNT_inc(value);
	if (SvTYPE(value) == SVt_PVCV) return newRV_inc(value);
	return newSVsv_flags(value, 0);
}

static void wump_magic_attach(pTHX_ SV *value, char kind, SV *initial) {
	AV *holder = newAV();
	av_extend(holder, 0);
	AvFILLp(holder) = 0;
	AvARRAY(holder)[0] = initial ? wump_magic_copy_cache(aTHX_ initial)
		: kind == '/' ? newSV(0) : NULL;
	MAGIC *mg = sv_magicext(value, (SV *)holder, PERL_MAGIC_ext,
		&wump_magic_vtbl, NULL, 0);
	mg->mg_private = (U16)(unsigned char)kind;
	mg->mg_flags |= MGf_LOCAL;
	SvREFCNT_dec(holder);
	if (kind == '\027') {
		U8 flags = *Perl_wump_warning_cache(aTHX);
		if (!(flags & G_WARN_ALL_MASK))
			flags = (flags & ~G_WARN_ON) | (initial && SvTRUE(initial) ? G_WARN_ON : G_WARN_OFF);
		av_store(holder, 1, newSVpvn((char *)&flags, 1));
	}
}

static int wump_magic_local(pTHX_ SV *value, MAGIC *source) {
	wump_magic_attach(aTHX_ value, (char)source->mg_private, NULL);
	return 0;
}

static char wump_magic_kind(pTHX_ SV *value) {
	if (!value || SvTYPE(value) < SVt_PVMG || !SvMAGIC(value)) return 0;
	char kind = 0;
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
		if (mg->mg_type == PERL_MAGIC_sv && mg->mg_virtual == &PL_vtbl_sv
			&& mg->mg_ptr && mg->mg_len == 1
			&& (mg->mg_ptr[0] == '/' || mg->mg_ptr[0] == '\\' || mg->mg_ptr[0] == '\027')) {
			kind = mg->mg_ptr[0];
		} else if (mg->mg_type == PERL_MAGIC_sigelem
			&& mg->mg_virtual == &PL_vtbl_sigelem && mg->mg_ptr) {
			STRLEN len = mg->mg_len;
			const char *key = mg->mg_ptr;
			if (mg->mg_len == HEf_SVKEY) {
				/* The scan runs under the publication lock. Read an existing
				 * key cache without stringification, allocation or magic. */
				SV *name = MUTABLE_SV(mg->mg_ptr);
				if (!SvPOK(name) || SvGMAGICAL(name) || SvROK(name)) return 0;
				key = SvPVX_const(name);
				len = SvCUR(name);
			}
			if (memEQs(key, len, "__DIE__")) kind = 'D';
			else if (memEQs(key, len, "__WARN__")) kind = 'W';
			else return 0;
		} else if ((mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == &wump_magic_vtbl)
			|| Perl_wump_publish_magic(mg)) {
			continue;
		} else if (mg->mg_type != PERL_MAGIC_backref && mg->mg_type != PERL_MAGIC_taint
			&& mg->mg_type != PERL_MAGIC_utf8 && mg->mg_type != PERL_MAGIC_regex_global
			&& mg->mg_type != PERL_MAGIC_vstring) {
			/* In particular, never treat tied scalars as builtin settings. */
			return 0;
		}
	}
	return kind;
}

char Perl_wump_magic_kind(pTHX_ SV *value) {
	/* A package scalar's first publication can upgrade its head and attach
	 * magic while another act checks for a localized builtin alias. This
	 * scan allocates nothing and invokes no callbacks, so share the short
	 * publication lock without adding an unwind record to the save stack. */
	bool guarded = value && Perl_wump_parallel(aTHX);
	if (guarded) Perl_wump_memory_lock(aTHX);
	char kind = wump_magic_kind(aTHX_ value);
	if (guarded) Perl_wump_memory_unlock(aTHX);
	return kind;
}

SV **Perl_wump_magic_owned(pTHX_ SV *value, char kind) {
	/* Perl temporarily clears SvMAGICAL while invoking magic handlers. */
	if (!value || SvTYPE(value) < SVt_PVMG || !SvMAGIC(value)) return NULL;
	MAGIC *mg = mg_findext(value, PERL_MAGIC_ext, &wump_magic_vtbl);
	if (!mg || mg->mg_private != (U16)(unsigned char)kind) return NULL;
	return &AvARRAY((AV *)mg->mg_obj)[0];
}

SV **Perl_wump_magic_target(pTHX_ SV *value, char kind) {
	SV **owned = Perl_wump_magic_owned(aTHX_ value, kind);
	if (owned) return owned;
	return kind == 'D' ? &aTHX->Idiehook : kind == 'W' ? &aTHX->Iwarnhook
		: kind == '/' ? &aTHX->Irs : &aTHX->Iors_sv;
}

SV **Perl_wump_magic_cache(pTHX_ char kind) {
	if (PL_wump_task) {
		for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
			if (slot->kind != 's' || slot->magic != kind) continue;
			SV **owned = Perl_wump_magic_owned(aTHX_ slot->value, kind);
			if (!owned) croak("Wump: separator binding lost its cache");
			return owned;
		}
	}
	return kind == '/' ? &aTHX->Irs : &aTHX->Iors_sv;
}

SV *Perl_wump_magic_new(pTHX_ char kind, SV *initial) {
	SV *value = initial && initial != PERL_WARNHOOK_FATAL
		? wump_magic_copy_cache(aTHX_ initial) : newSV(0);
	char name[2] = {kind, 0};
	if (kind == 'D' || kind == 'W') {
		const char *key = kind == 'D' ? "__DIE__" : "__WARN__";
		sv_magicext(value, NULL, PERL_MAGIC_sigelem, &PL_vtbl_sigelem, key, strlen(key));
	} else sv_magicext(value, NULL, PERL_MAGIC_sv, &PL_vtbl_sv, name, 1);
	wump_magic_attach(aTHX_ value, kind, initial);
	return value;
}

void Perl_wump_hook_store(pTHX_ SV *value, char kind) {
	if (!value || Perl_wump_magic_owned(aTHX_ value, kind)) return;
	/* Native hv_store transfers this exact SV to the hash; XS may assign
	 * through it and invoke set-magic after the store. Preserve its identity. */
	if (SvMAGICAL(value)) croak("Wump: magical replacement of a hook cell is unsupported");
	const char *key = kind == 'D' ? "__DIE__" : "__WARN__";
	sv_magicext(value, NULL, PERL_MAGIC_sigelem, &PL_vtbl_sigelem, key, strlen(key));
	wump_magic_attach(aTHX_ value, kind, value);
}

SV *Perl_wump_magic_copy(pTHX_ SV *value) {
	char kind = Perl_wump_magic_kind(aTHX_ value);
	if (kind == '\027') {
		U8 flags = *Perl_wump_warning_target(aTHX_ value);
		SV *initial = sv_2mortal(newSViv(!!(flags & G_WARN_ON)));
		SV *copy = Perl_wump_magic_new(aTHX_ kind, initial);
		*Perl_wump_warning_owned(aTHX_ copy) = flags;
		return copy;
	}
	return kind ? Perl_wump_magic_new(aTHX_ kind,
		*Perl_wump_magic_target(aTHX_ value, kind)) : newSVsv(value);
}

U8 *Perl_wump_warning_owned(pTHX_ SV *value) {
	if (!value || SvTYPE(value) < SVt_PVMG || !SvMAGIC(value)) return NULL;
	MAGIC *mg = mg_findext(value, PERL_MAGIC_ext, &wump_magic_vtbl);
	if (!mg || mg->mg_private != '\027') return NULL;
	SV *flags = AvARRAY((AV *)mg->mg_obj)[1];
	/* Detached storage also keeps interpreter-cloned copies independent. */
	sv_force_normal_flags(flags, 0);
	return (U8 *)SvPVX(flags);
}

U8 *Perl_wump_warning_target(pTHX_ SV *value) {
	U8 *owned = Perl_wump_warning_owned(aTHX_ value);
	return owned ? owned : &aTHX->Idowarn;
}

U8 *Perl_wump_warning_cache(pTHX) {
	if (PL_wump_task) {
		for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
			if (slot->magic == '\027') return Perl_wump_warning_owned(aTHX_ slot->value);
		}
	}
	return &aTHX->Idowarn;
}

char Perl_wump_hook_kind(pTHX_ HV *hv, SV *key) {
	bool signal_hash = FALSE;
	if (!SvMAGICAL(hv)) return 0;
	for (MAGIC *mg = SvMAGIC(hv); mg; mg = mg->mg_moremagic) {
		if (mg->mg_type == PERL_MAGIC_sig && mg->mg_virtual == &PL_vtbl_sig)
			signal_hash = TRUE;
		else if (mg->mg_type != PERL_MAGIC_backref && !Perl_wump_element_magic(mg)
			&& !Perl_wump_publish_magic(mg))
			return 0;
	}
	if (!signal_hash) return 0;
	STRLEN len;
	const char *name = SvPV_const(key, len);
	return memEQs(name, len, "__DIE__") ? 'D' : memEQs(name, len, "__WARN__") ? 'W' : 0;
}

SV **Perl_wump_hook_cache(pTHX_ char kind) {
	SV *value = NULL;
	UV sequence = 0;
	if (PL_wump_task) {
		for (wump_local *slot = PL_wump_task->locals; slot; slot = slot->next) {
			if (slot->magic == kind && slot->sequence > sequence) {
				sequence = slot->sequence;
				value = slot->value;
			}
		}
		for (wump_element *slot = PL_wump_task->elements; slot; slot = slot->next) {
			if (slot->hook != kind || slot->sequence <= sequence) continue;
			for (STRLEN i = 0; i <= HvMAX(slot->cell); i++) {
				HE *he = HvARRAY(slot->cell)[i];
				if (he) { value = HeVAL(he); sequence = slot->sequence; break; }
			}
		}
	}
	return value ? Perl_wump_magic_owned(aTHX_ value, kind)
		: kind == 'D' ? &aTHX->Idiehook : &aTHX->Iwarnhook;
}

void Perl_wump_magic_scope(pTHX_ char kind) {
	if (!PL_wump_task) return;
	bool hook = kind == 'D' || kind == 'W';
	SV *value = Perl_wump_magic_new(aTHX_ kind,
		*(hook ? Perl_wump_hook_cache(aTHX_ kind) : Perl_wump_magic_cache(aTHX_ kind)));
	char name[2] = {kind, 0};
	GV *gv = hook ? gv_fetchpvs("SIG", GV_ADD, SVt_PVHV)
		: gv_fetchpvn_flags(name, 1, GV_ADD | GV_NOTQUAL, SVt_PV);
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task, gv, hook ? 'k' : 's', value);
	slot->magic = kind;
	/* Internal I/O overrides are not child context. */
	slot->pocket = TRUE;
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
}
