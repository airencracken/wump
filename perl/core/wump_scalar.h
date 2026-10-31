/* Shared by the public GV accessor and generated active opcode bodies.
 * No allocation, callback or migration occurs while selecting this slot. */
PERL_STATIC_INLINE SV **S_wump_canonical_scalar(GV *gv, GV *selected) {
	/* Effective-glob aliases may name a match-result cell. Let the full
	 * accessor preserve regex magic and alias identity in that case. */
	GV *effective = GvEGV(gv);
	return effective && effective != gv ? NULL : &GvGP(selected)->gp_sv;
}

PERL_STATIC_INLINE SV **S_wump_private_scalar(pTHX_ struct wump_perl_task *task, GV *gv) {
	if (!task || task->locals) return NULL;
	GV *selected;
	if (gv == aTHX->Idefgv || (!task->main && gv == task->Idefgv))
		selected = task->main ? aTHX->Idefgv : task->Idefgv;
	else if (gv == aTHX->Ierrgv || (!task->main && gv == task->Ierrgv))
		selected = task->main ? aTHX->Ierrgv : task->Ierrgv;
	else if (gv == aTHX->Ireplgv || (!task->main && gv == task->Ireplgv))
		selected = task->main ? aTHX->Ireplgv : task->Ireplgv;
	else return NULL;
	return S_wump_canonical_scalar(gv, selected);
}
