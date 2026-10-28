/* Included by sv.c. A retired private shell owns the old body and PV;
 * the published SV keeps its identity and its original magic list. */
bool Perl_wump_cow_retain(pTHX_ SV *value) {
	sv_buf_to_rw(value);
	U8 *counter = (U8 *)(SvPVX_mutable(value) + SvLEN(value) - 1);
	U8 count = __atomic_load_n(counter, __ATOMIC_ACQUIRE);
	while (count < SV_COW_REFCNT_MAX) {
		U8 next = count + 1;
		if (__atomic_compare_exchange_n(counter, &count, next, FALSE, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
			sv_buf_to_ro(value);
			return TRUE;
		}
	}
	sv_buf_to_ro(value);
	return FALSE;
}

void Perl_wump_sv_detach(pTHX_ SV *value) {
	if (SvTYPE(value) != SVt_PVMG || SvROK(value) || SvVALID(value)) return;
	U32 original = SvFLAGS(value);
	const U32 retained_flags = SVTYPEMASK | SVf_IOK | SVp_IOK | SVf_NOK | SVp_NOK
		| SVf_POK | SVp_POK | SVf_IVisUV | SVf_UTF8 | SVf_IsCOW | SVf_FAKE | SVf_OOK | SVppv_STATIC;
	MAGIC *magic = SvMAGIC(value);
	HV *stash = SvSTASH(value);
	SV *copy = newSV_type(SVt_PVMG);
	ENTER;
	SAVEFREESV(copy);
	/* PVMG has no leading ghost fields. Build a privately owned body/PV
	 * before the nonthrowing commit; never duplicate magic ownership. */
	Copy(SvANY(value), SvANY(copy), sizeof(XPVMG), char);
	SvMAGIC_set(copy, NULL);
	SvSTASH_set(copy, NULL);
	SvPV_set(copy, NULL);
	SvLEN_set(copy, 0);
	SvFLAGS(copy) = original & retained_flags & ~(SVf_IsCOW | SVf_FAKE | SVf_OOK | SVppv_STATIC);
	if (SvPVX_const(value)) {
		STRLEN length = SvCUR(value);
		char *buffer;
		Newx(buffer, length + 1, char);
		Copy(SvPVX_const(value), buffer, length, char);
		buffer[length] = '\0';
		SvPV_set(copy, buffer);
		SvLEN_set(copy, length + 1);
	}
	Perl_wump_mutation_keep(aTHX_ value, copy);
	struct wump_retired *retired = Perl_wump_retire_prepare(aTHX_ copy);
	void *body = SvANY(value);
	char *buffer = SvPVX_mutable(value);
	char *fresh = SvPVX_mutable(copy);
	SvANY(value) = SvANY(copy);
	SvANY(copy) = body;
	SvPV_set(value, fresh);
	SvPV_set(copy, buffer);
	SvMAGIC_set(value, magic);
	SvSTASH_set(value, stash);
	SvMAGIC_set(copy, NULL);
	SvSTASH_set(copy, NULL);
	SvFLAGS(value) &= ~(SVf_IsCOW | SVf_FAKE | SVf_OOK | SVppv_STATIC);
	SvFLAGS(copy) = original & retained_flags;
	Perl_wump_storage_changed(aTHX_ value);
	Perl_wump_retire_commit(aTHX_ retired);
	LEAVE;
}

void Perl_wump_memory_clone(pTHX) {
	/* clone copies extension magic, but each interpreter owns a new domain.
	 * Register copied markers only after all clone fixups have completed. */
	for (SV *arena = PL_sv_arenaroot; arena; arena = (SV *)SvANY(arena)) {
		SV *end = arena + SvREFCNT(arena);
		for (SV *value = arena + 1; value < end; value++) {
			if (SvTYPE(value) == SVTYPEMASK || SvTYPE(value) < SVt_PVMG || !SvREFCNT(value)) continue;
			for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
				if (Perl_wump_publish_magic(mg) && mg->mg_private == 2) {
					Perl_wump_memory_mark(aTHX_ value, 2);
					break;
				}
			}
		}
	}
}
