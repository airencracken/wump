/* Included by av.c. Old real storage retains its element ownership until
 * the last outstanding borrow leaves the interpreter's lifetime domain. */
void Perl_wump_av_detach(pTHX_ AV *value) {
	if (!AvREAL(value)) croak("Wump: borrowing non-real array storage is not supported");
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
		if (!Perl_wump_publish_magic(mg))
			croak("Wump: borrowing magical array storage is not supported");
	if (!AvALLOC(value)) return;
	AV *copy = newAV();
	ENTER;
	SAVEFREESV(copy);
	SSize_t offset = AvARRAY(value) - AvALLOC(value);
	SSize_t count = offset + AvMAX(value) + 1;
	SV **storage;
	Newxz(storage, count, SV *);
	AvALLOC(copy) = storage;
	AvARRAY(copy) = storage + offset;
	AvMAX(copy) = AvMAX(value);
	AvFILLp(copy) = AvFILLp(value);
	for (SSize_t i = 0; i <= AvFILLp(value); i++)
		AvARRAY(copy)[i] = SvREFCNT_inc(AvARRAY(value)[i]);
	Perl_wump_mutation_keep(aTHX_ (SV *)value, (SV *)copy);
	struct wump_retired *retired = Perl_wump_retire_prepare(aTHX_ (SV *)copy);
	SV **old_alloc = AvALLOC(value), **old_array = AvARRAY(value);
	AvALLOC(value) = storage;
	AvARRAY(value) = storage + offset;
	AvALLOC(copy) = old_alloc;
	AvARRAY(copy) = old_array;
	Perl_wump_storage_changed(aTHX_ (SV *)value);
	Perl_wump_retire_commit(aTHX_ retired);
	LEAVE;
}
