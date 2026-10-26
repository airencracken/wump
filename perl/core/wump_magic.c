/* Separator caches belong to their scalar cells, including escaped references.
 * A hidden one-element AV supplies stable pointer storage and owns the cache;
 * ordinary magic-object refcounting/cloning handles its lifetime. */
static int wump_magic_local(pTHX_ SV *value, MAGIC *source);
static const MGVTBL wump_magic_vtbl = { .svt_local = wump_magic_local };

static void wump_magic_attach(pTHX_ SV *value, char kind, SV *initial) {
	AV *holder = newAV();
	av_extend(holder, 0);
	AvFILLp(holder) = 0;
	AvARRAY(holder)[0] = initial ? newSVsv_flags(initial, 0)
		: kind == '/' ? newSV(0) : NULL;
	MAGIC *mg = sv_magicext(value, (SV *)holder, PERL_MAGIC_ext,
		&wump_magic_vtbl, NULL, 0);
	mg->mg_private = (U16)(unsigned char)kind;
	mg->mg_flags |= MGf_LOCAL;
	SvREFCNT_dec(holder);
}

static int wump_magic_local(pTHX_ SV *value, MAGIC *source) {
	wump_magic_attach(aTHX_ value, (char)source->mg_private, NULL);
	return 0;
}

char Perl_wump_magic_kind(pTHX_ SV *value) {
	if (!value || SvTYPE(value) < SVt_PVMG || !SvMAGIC(value)) return 0;
	char kind = 0;
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
		if (mg->mg_type == PERL_MAGIC_sv && mg->mg_virtual == &PL_vtbl_sv
			&& mg->mg_ptr && mg->mg_len == 1
			&& (mg->mg_ptr[0] == '/' || mg->mg_ptr[0] == '\\')) {
			kind = mg->mg_ptr[0];
		} else if (mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == &wump_magic_vtbl) {
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
	return kind == '/' ? &aTHX->Irs : &aTHX->Iors_sv;
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
	SV *value = initial ? newSVsv_flags(initial, 0) : newSV(0);
	char name[2] = {kind, 0};
	sv_magicext(value, NULL, PERL_MAGIC_sv, &PL_vtbl_sv, name, 1);
	wump_magic_attach(aTHX_ value, kind, initial);
	return value;
}

SV *Perl_wump_magic_copy(pTHX_ SV *value) {
	char kind = Perl_wump_magic_kind(aTHX_ value);
	return kind ? Perl_wump_magic_new(aTHX_ kind,
		*Perl_wump_magic_target(aTHX_ value, kind)) : newSVsv(value);
}

void Perl_wump_magic_scope(pTHX_ char kind) {
	if (!PL_wump_task) return;
	SV *value = Perl_wump_magic_new(aTHX_ kind, *Perl_wump_magic_cache(aTHX_ kind));
	char name[2] = {kind, 0};
	GV *gv = gv_fetchpvn_flags(name, 1, GV_ADD | GV_NOTQUAL, SVt_PV);
	wump_local *slot = wump_local_add(aTHX_ PL_wump_task, gv, 's', value);
	slot->magic = kind;
	/* Internal readline/glob/say overrides are not child context. */
	slot->pocket = TRUE;
	SAVEDESTRUCTOR_X(wump_local_pop, slot);
}
