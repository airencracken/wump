/* Included after the lifetime domain. A read probe retains existing cells;
 * missing cells are rechecked under a writer before creation and retention.
 * No raw slot/HE crosses the reader-to-writer handoff. */
static bool wump_lvalue_array(pTHX_ AV *value) {
	if (SvTYPE(value) != SVt_PVAV || !AvREAL(value) || SvREADONLY(value)
		|| Perl_wump_overlay_active(aTHX_ (SV *)value)) return FALSE;
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
		if (!Perl_wump_publish_magic(mg) && !Perl_wump_element_magic(mg)
			&& mg->mg_type != PERL_MAGIC_backref) return FALSE;
	return TRUE;
}

static SV *wump_lvalue_array_cell(AV *value, SSize_t index) {
	if (index < 0) index += AvFILLp(value) + 1;
	return index >= 0 && index <= AvFILLp(value) ? AvARRAY(value)[index] : NULL;
}

static SSize_t wump_lvalue_deferred_index(AV *value, SSize_t index) {
	/* Match pp_aelem's deferred-hole normalization, including its distinct
	 * treatment of a negative index which still lies outside the array. */
	SSize_t last = AvFILLp(value);
	if (index < 0 && last >= 0 && index >= -last) index += last;
	return index;
}

SV *Perl_wump_lvalue_av(pTHX_ AV *value, SSize_t index, bool defer, bool *handled) {
	*handled = FALSE;
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	wump_borrow *probe = wump_borrow_start(aTHX_ (SV *)value);
	if (!probe) return NULL;
	bool plain = wump_lvalue_array(aTHX_ value);
	SV *result = plain ? wump_lvalue_array_cell(value, index) : NULL;
	if (plain && result && result != &PL_sv_undef) {
		wump_load_keep(aTHX_ holder, result);
		*handled = TRUE;
	} else if (plain && !result && defer) {
		SSize_t at = wump_lvalue_deferred_index(value, index);
		if (at < 0 || at > AvFILLp(value)) {
			result = sv_2mortal(newSVavdefelem(value, at, TRUE));
			*handled = TRUE;
		}
	}
	Perl_wump_capture_end(aTHX_ probe);
	if (*handled || !plain || result == &PL_sv_undef) return *handled ? result : NULL;

	struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ (SV *)value);
	bool fresh_proxy = FALSE;
	if (wump_lvalue_array(aTHX_ value)) {
		result = wump_lvalue_array_cell(value, index);
		if (!result && defer) {
			SSize_t at = wump_lvalue_deferred_index(value, index);
			fresh_proxy = at < 0 || at > AvFILLp(value);
			result = fresh_proxy ? sv_2mortal(newSVavdefelem(value, at, TRUE))
				: av_nonelem(value, at);
		} else if (!result) {
			SV **slot = av_fetch(value, index, TRUE);
			result = slot ? *slot : NULL;
		}
		if (result && result != &PL_sv_undef) {
			/* A fresh deferred proxy is already mortal; real cells need an
			 * independent head reference before the container writer ends. */
			if (!fresh_proxy)
				wump_load_keep(aTHX_ holder, result);
			*handled = TRUE;
		}
	}
	Perl_wump_mutation_end(aTHX_ guard);
	return *handled ? result : NULL;
}

static SV *wump_lvalue_key(pTHX_ SV *key) {
	wump_borrow *probe = wump_borrow_start(aTHX_ key);
	bool plain = SvTYPE(key) <= SVt_PVMG && !SvROK(key) && !SvOBJECT(key)
		&& !SvVALID(key) && SvPOK(key);
	if (plain && SvTYPE(key) == SVt_PVMG)
		for (MAGIC *mg = SvMAGIC(key); mg; mg = mg->mg_moremagic)
			if (!Perl_wump_publish_magic(mg)) plain = FALSE;
	SV *copy = plain ? sv_2mortal(newSVpvn_flags(SvPVX_const(key), SvCUR(key),
		SvUTF8(key) ? SVf_UTF8 : 0)) : NULL;
	Perl_wump_capture_end(aTHX_ probe);
	return copy;
}

static HE *wump_lvalue_hash_entry(pTHX_ HV *value, SV *key, bool create) {
	return (HE *)hv_common(value, NULL, SvPVX_const(key), SvCUR(key),
		SvUTF8(key) ? HVhek_UTF8 : 0, create ? HV_FETCH_LVALUE : 0, NULL, 0);
}

SV *Perl_wump_lvalue_hv(pTHX_ HV *value, SV *key, bool defer, bool *handled) {
	*handled = FALSE;
	SV *copy = wump_lvalue_key(aTHX_ key);
	if (!copy) return NULL;
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	wump_borrow *probe = wump_borrow_start(aTHX_ (SV *)value);
	if (!probe) return NULL;
	bool plain = Perl_wump_hv_readable(aTHX_ value) && !SvREADONLY(value);
	HE *entry = plain ? wump_lvalue_hash_entry(aTHX_ value, copy, FALSE) : NULL;
	SV *result = entry ? HeVAL(entry) : NULL;
	if (plain && result && result != &PL_sv_undef) {
		wump_load_keep(aTHX_ holder, result);
		*handled = TRUE;
	} else if (plain && !result && defer) {
		result = sv_2mortal(newSV_type(SVt_PVLV));
		LvTYPE(result) = 'y';
		sv_magic(result, copy, PERL_MAGIC_defelem, NULL, 0);
		LvTARG(result) = SvREFCNT_inc(value);
		LvTARGLEN(result) = 1;
		*handled = TRUE;
	}
	Perl_wump_capture_end(aTHX_ probe);
	if (*handled || !plain || result == &PL_sv_undef) return *handled ? result : NULL;

	struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ (SV *)value);
	if (Perl_wump_hv_readable(aTHX_ value) && !SvREADONLY(value)) {
		entry = wump_lvalue_hash_entry(aTHX_ value, copy, TRUE);
		result = entry ? HeVAL(entry) : NULL;
		if (result && result != &PL_sv_undef) {
			wump_load_keep(aTHX_ holder, result);
			*handled = TRUE;
		}
	}
	Perl_wump_mutation_end(aTHX_ guard);
	return *handled ? result : NULL;
}

void Perl_wump_vivify_value(pTHX_ SV *value, U32 kind) {
	/* The caller owns the source writer. Root and publish the entire new
	 * referent before committing the RV, so a publication exception cannot
	 * expose an unclassified graph or lose the newly allocated value. */
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	SV *target = kind == OPpDEREF_AV ? (SV *)newAV()
		: kind == OPpDEREF_HV ? (SV *)newHV() : newSV(0);
	SvRV_set(holder, target);
	SvROK_on(holder);
	Perl_wump_publish_store(aTHX_ value, target);
	prepare_SV_for_RV(value);
	SvRV_set(value, SvREFCNT_inc(target));
	SvROK_on(value);
}
