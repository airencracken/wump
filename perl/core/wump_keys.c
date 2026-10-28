/* Included by hv.c. Key bytes/flags are immutable after publication.
 * Retains require an existing reference. Table lookup/removal and resize
 * serialize per interpreter; native locks never cross a scheduling point. */
static struct shared_he *wump_shared_entry(const HEK *hek) {
	return (struct shared_he *)((char *)hek - STRUCT_OFFSET(struct shared_he, shared_he_hek));
}

HEK *Perl_wump_hek_retain(const HEK *hek) {
	__atomic_add_fetch(&wump_shared_entry(hek)->shared_he_he.he_valu.hent_refcount, 1, __ATOMIC_RELAXED);
	return (HEK *)hek;
}

static HE *wump_find_key(pTHX_ const char *str, STRLEN len, U32 hash, U8 flags) {
	for (HE *entry = HvARRAY(PL_strtab)[hash & HvMAX(PL_strtab)]; entry; entry = HeNEXT(entry)) {
		if (HeHASH(entry) == hash && HeKLEN(entry) == (SSize_t)len
			&& HeKFLAGS(entry) == flags && (HeKEY(entry) == str || memEQ(HeKEY(entry), str, len)))
			return entry;
	}
	return NULL;
}

static HEK *wump_share_key(pTHX_ const char *str, STRLEN len, U32 hash, int flags) {
	if (UNLIKELY(len > (STRLEN)I32_MAX)) croak("Sorry, hash keys must be smaller than 2**31 bytes");
	assert(!(flags & HVhek_NOTSHARED));
	U8 stored = flags & HVhek_STORAGE_MASK;
	MUTEX_LOCK(&aTHX->Iwump_keys_mutex);
	HE *entry = wump_find_key(aTHX_ str, len, hash, stored);
	if (entry) {
		HEK *result = Perl_wump_hek_retain(HeKEY_hek(entry));
		MUTEX_UNLOCK(&aTHX->Iwump_keys_mutex);
		if (flags & HVhek_FREEKEY) Safefree(str);
		return result;
	}
	MUTEX_UNLOCK(&aTHX->Iwump_keys_mutex);
	/* Allocate before locking: OOM can run END blocks, and diagnostics can
	 * reenter Perl. Recheck after allocation because a peer can win. */
	char *memory;
	Newx(memory, STRUCT_OFFSET(struct shared_he, shared_he_hek.hek_key[0]) + len + 2, char);
	struct shared_he *candidate = (struct shared_he *)memory;
	HEK *key = &candidate->shared_he_hek;
	Copy(str, HEK_KEY(key), len, char);
	HEK_KEY(key)[len] = 0;
	HEK_LEN(key) = len;
	HEK_HASH(key) = hash;
	HEK_FLAGS(key) = stored;
	HeKEY_hek(&candidate->shared_he_he) = key;
	candidate->shared_he_he.he_valu.hent_refcount = 1;
	MUTEX_LOCK(&aTHX->Iwump_keys_mutex);
	entry = wump_find_key(aTHX_ str, len, hash, stored);
	if (entry) {
		key = Perl_wump_hek_retain(HeKEY_hek(entry));
	} else {
		HE **head = &HvARRAY(PL_strtab)[hash & HvMAX(PL_strtab)];
		bool collided = *head != NULL;
		HeNEXT(&candidate->shared_he_he) = *head;
		*head = &candidate->shared_he_he;
		candidate = NULL;
		XPVHV *body = (XPVHV *)SvANY(PL_strtab);
		body->xhv_keys++;
		if (collided && DO_HSPLIT(body)) {
			STRLEN oldsize = body->xhv_max + 1;
			S_hsplit(aTHX_ PL_strtab, oldsize, oldsize * 2);
		}
	}
	MUTEX_UNLOCK(&aTHX->Iwump_keys_mutex);
	Safefree(candidate);
	if (flags & HVhek_FREEKEY) Safefree(str);
	return key;
}

static void wump_unshare_key(pTHX_ const HEK *hek, const char *str, I32 len, U32 hash) {
	const char *warning_text = hek ? HEK_KEY(hek) : str;
	int flags = 0;
	struct shared_he *shared = NULL;
	if (hek) {
		assert(!(HEK_FLAGS(hek) & HVhek_NOTSHARED));
		shared = wump_shared_entry(hek);
		assert(shared->shared_he_he.hent_hek == hek);
		/* Only a table-locked drop may reach zero. Retains and other
		 * nonterminal drops can run concurrently, so use a CAS loop. */
		Size_t refs = __atomic_load_n(&shared->shared_he_he.he_valu.hent_refcount, __ATOMIC_ACQUIRE);
		while (refs > 1) {
			if (__atomic_compare_exchange_n(&shared->shared_he_he.he_valu.hent_refcount,
				&refs, refs - 1, 1, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return;
		}
		hash = HEK_HASH(hek);
	} else if (len < 0) {
		STRLEN size = -(SSize_t)len;
		void *allocated = NULL;
		if (!utf8_to_bytes_new_pv((const U8 **)&str, &size, &allocated)) flags = HVhek_UTF8;
		else {
			flags = allocated ? HVhek_WASUTF8 | HVhek_FREEKEY : 0;
			if (allocated) PERL_HASH(hash, str, size);
		}
		len = size;
	}
	MUTEX_LOCK(&aTHX->Iwump_keys_mutex);
	HE **link = &HvARRAY(PL_strtab)[hash & HvMAX(PL_strtab)];
	HE *entry;
	for (entry = *link; entry; link = &HeNEXT(entry), entry = *link) {
		if (shared ? entry == &shared->shared_he_he
			: HeHASH(entry) == hash && HeKLEN(entry) == len && HeKFLAGS(entry) == (flags & HVhek_STORAGE_MASK)
				&& (HeKEY(entry) == str || memEQ(HeKEY(entry), str, len))) break;
	}
	bool missing = entry == NULL;
	HE *retired = NULL;
	if (entry && __atomic_sub_fetch(&entry->he_valu.hent_refcount, 1, __ATOMIC_ACQ_REL) == 0) {
		*link = HeNEXT(entry);
		HvTOTALKEYS(PL_strtab)--;
		retired = entry;
	}
	MUTEX_UNLOCK(&aTHX->Iwump_keys_mutex);
	Safefree(retired);
	if (flags & HVhek_FREEKEY) Safefree(str);
	/* Release conversion buffers before a hook can throw or be abandoned.
	 * Report the caller's original spelling, whose lifetime it owns. */
	if (missing) ck_warner_d(packWARN(WARN_INTERNAL),
		"Attempt to free nonexistent shared string '%s'%s" pTHX__FORMAT,
		warning_text, flags & HVhek_UTF8 ? " (utf8)" : "" pTHX__VALUE);
}
