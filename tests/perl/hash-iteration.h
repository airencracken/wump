/* Included after read-cases.h by the C/C++ and concurrent reader fixtures. */
enum { hash_entries = 259 };
typedef struct hash_state {
	HV *value;
	U32 flags;
	void *body;
	HE **buckets;
	I32 riter;
	HE *eiter;
	STRLEN keys, max;
#ifdef PERL_HASH_RANDOMIZE_KEYS
	U32 random, last_random;
#endif
} hash_state;

static void capture_hash(hash_state *test) {
	HV *hv = test->value;
	test->flags = SvFLAGS(hv);
	test->body = SvANY(hv);
	test->buckets = HvARRAY(hv);
	test->riter = HvRITER_get(hv);
	test->eiter = HvEITER_get(hv);
	test->keys = HvTOTALKEYS(hv);
	test->max = HvMAX(hv);
#ifdef PERL_HASH_RANDOMIZE_KEYS
	test->random = HvRAND_get(hv);
	test->last_random = HvHasAUX(hv) ? HvAUX(hv)->xhv_last_rand : 0;
#endif
}

static void unchanged_hash(const hash_state *test) {
	HV *hv = test->value;
	CHECK(SvFLAGS(hv) == test->flags && SvANY(hv) == test->body);
	CHECK(HvARRAY(hv) == test->buckets);
	CHECK(HvRITER_get(hv) == test->riter && HvEITER_get(hv) == test->eiter);
	CHECK(HvTOTALKEYS(hv) == test->keys && HvMAX(hv) == test->max);
#ifdef PERL_HASH_RANDOMIZE_KEYS
	CHECK(HvRAND_get(hv) == test->random);
	CHECK(!HvHasAUX(hv) || HvAUX(hv)->xhv_last_rand == test->last_random);
#endif
}

static void build_hash(pTHX_ hash_state *test) {
	HV *hv = test->value = newHV();
	hv_ksplit(hv, 512);
	/* Exercise a long collision chain using correctly computed hashes. */
	int inserted = 0;
	for (unsigned candidate = 0; inserted < 64 && candidate < 1000000; candidate++) {
		char key[32];
		int len = snprintf(key, sizeof(key), "collision%u", candidate);
		U32 hash;
		PERL_HASH(hash, key, len);
		if (hash & HvMAX(hv)) continue;
		CHECK(hv_store(hv, key, len, newSViv(inserted), hash));
		inserted++;
	}
	CHECK(inserted == 64);
	for (int i = 64; i < hash_entries - 3; i++) {
		char key[32];
		int len = snprintf(key, sizeof(key), "entry%d", i);
		CHECK(hv_store(hv, key, len, newSViv(i), 0));
	}
	CHECK(hv_store(hv, "", 0, newSViv(hash_entries - 3), 0));
	CHECK(hv_store(hv, "nul\0key", 7, newSViv(hash_entries - 2), 0));
	CHECK(hv_store_flags(hv, "\xe2\x82\xac", 3, newSViv(hash_entries - 1), 0, HVhek_UTF8));
	/* Leave the root iterator partway through traversal before publication. */
	CHECK(hv_iterinit(hv) == hash_entries);
	CHECK(hv_iternext(hv));
	Perl_wump_publish(aTHX_ (SV *)hv);
	capture_hash(test);
}

static void exercise_hash(pTHX_ const hash_state *test, bool clone) {
	HV *hv = test->value;
	bool seen[hash_entries] = {0};
	CHECK(hv_iterinit(hv) == hash_entries);
	unchanged_hash(test);
	int count = 0;
	HE *entry;
	while ((entry = hv_iternext(hv))) {
		IV value = SvIV(hv_iterval(hv, entry));
		CHECK(value >= 0 && value < hash_entries && !seen[value]);
		seen[value] = TRUE;
		count++;
	}
	CHECK(count == hash_entries);
	unchanged_hash(test);
	/* Exhaustion restarts without an explicit reset. */
	CHECK(hv_iternext(hv));
	if (clone) {
		HV *copy = newHVhv(hv);
		CHECK(HvUSEDKEYS(copy) == hash_entries);
		SvREFCNT_dec(copy);
		unchanged_hash(test);
	}
	CHECK(hv_iterinit(hv) == hash_entries);
	unchanged_hash(test);
}
