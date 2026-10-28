#include "EXTERN.h"
#include "perl.h"
#include <stdio.h>

static int roundtrip(pTHX_ const char *text, I32 len) {
	U32 hash;
	PERL_HASH(hash, text, len < 0 ? -len : len);
	HEK *key = share_hek(text, len, hash);
	const HEK *view = key;
	share_hek_hek(view);
	unsharepvn(text, len, hash);
	Size_t count = __atomic_load_n(&((struct shared_he *)((char *)key
		- STRUCT_OFFSET(struct shared_he, shared_he_hek)))->shared_he_he.he_valu.hent_refcount,
		__ATOMIC_ACQUIRE);
	if (count != 1) {
		fprintf(stderr, "FAIL: legacy unshare with length %d left %zu references\n", len, count);
		return 1;
	}
	unshare_hek(key);
	return 0;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	if (!interp) return 1;
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	SV *scratch = newSV_type(SVt_PVNV);
	SvREFCNT_dec(scratch);
	STRLEN before = HvTOTALKEYS(PL_strtab);
	if (roundtrip(aTHX_ "wump-ascii", 10) || roundtrip(aTHX_ "wump-ascii", -10)
		|| roundtrip(aTHX_ "nul\0key", 7) || roundtrip(aTHX_ "\xc3\xa9", -2)
		|| roundtrip(aTHX_ "\xe2\x82\xac", -3)) return 1;
	if (HvTOTALKEYS(PL_strtab) != before) return 1;
	PL_perl_destruct_level = 2;
	if (perl_destruct(interp) != 0) return 1;
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - legacy key release normalizes ASCII, embedded NULs, downgraded Latin-1, and UTF-8");
	return 0;
}
