/* Included by hv.c after its private HE allocators. Copy the chains, not
 * their scalar values, so old buckets/entries remain valid without changing
 * lvalue identity in the live table. */
static HE *wump_copy_entry(pTHX_ HE *entry) {
	assert(HeKLEN(entry) != HEf_SVKEY);
	HE *copy = new_HE();
	HeNEXT(copy) = NULL;
	HeVAL(copy) = SvREFCNT_inc(HeVAL(entry));
	if (HeKFLAGS(entry) & HVhek_NOTSHARED)
		HeKEY_hek(copy) = save_hek_flags(HeKEY(entry), HeKLEN(entry), HeHASH(entry), HeKFLAGS(entry));
	else HeKEY_hek(copy) = share_hek_hek(HeKEY_hek(entry));
	return copy;
}

void Perl_wump_hv_detach(pTHX_ HV *value) {
	if (!Perl_wump_hv_readable(aTHX_ value))
		croak("Wump: borrowing magical hash storage is not supported");
	if (!HvARRAY(value)) return;
	HV *copy = newHV();
	ENTER;
	SAVEFREESV(copy);
	HE **storage;
	Newxz(storage, HvMAX(value) + 1, HE *);
	HvARRAY(copy) = storage;
	HvMAX(copy) = HvMAX(value);
	/* The copied table has its own header and no publication/weak magic. */
	if (HvSHAREKEYS(value)) HvSHAREKEYS_on(copy);
	else HvSHAREKEYS_off(copy);
	if (HvHASKFLAGS(value)) HvHASKFLAGS_on(copy);
	HE *current = HvEITER_get(value), *mapped = NULL, *mapped_next = NULL;
	for (STRLEN i = 0; i <= HvMAX(value); i++) {
		HE **tail = &storage[i];
		for (HE *entry = HvARRAY(value)[i]; entry; entry = HeNEXT(entry)) {
			HE *fresh = wump_copy_entry(aTHX_ entry);
			*tail = fresh;
			tail = &HeNEXT(fresh);
			HvTOTALKEYS(copy)++;
			if (entry == current) mapped = fresh;
			if (current && entry == HeNEXT(current)) mapped_next = fresh;
		}
	}
	HE *orphan = NULL;
	if (current && HvLAZYDEL(value)) {
		orphan = wump_copy_entry(aTHX_ current);
		HeNEXT(orphan) = mapped_next;
		/* Give the temporary header its own aux block before commit. */
		hv_iterinit(copy);
		HvEITER_set(copy, orphan);
		HvLAZYDEL_on(copy);
	}
	Perl_wump_mutation_keep(aTHX_ (SV *)value, (SV *)copy);
	struct wump_retired *retired = Perl_wump_retire_prepare(aTHX_ (SV *)copy);
	HE **old = HvARRAY(value);
	HvARRAY(value) = storage;
	HvARRAY(copy) = old;
	if (orphan) {
		HvEITER_set(copy, current);
		HvLAZYDEL_on(copy);
		HvEITER_set(value, orphan);
	} else if (current) HvEITER_set(value, mapped);
	Perl_wump_storage_changed(aTHX_ (SV *)value);
	Perl_wump_retire_commit(aTHX_ retired);
	LEAVE;
}
