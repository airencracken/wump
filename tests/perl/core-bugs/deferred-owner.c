/* Minimal embedding reproducer. No Wump APIs, patches or runtime required.
 * Exit 1 means a nonextendible deferred element leaked its array owner. */
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include <stdio.h>

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	if (!interp) return 2;
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	char program[] = "deferred-owner", option[] = "-e", code[] = "0";
	char *embedding[] = {program, option, code, NULL};
	if (perl_parse(interp, NULL, 3, embedding, NULL)) return 2;
	dTHXa(interp);
	AV *owner = newAV();
	av_push(owner, newSViv(1));
	SV *weak = newRV_inc((SV *)owner);
	sv_rvweaken(weak);
	SV *delegate = Perl_newSVavdefelem(aTHX_ owner, 5, FALSE);
	SvREFCNT_dec(owner); /* delegate now holds the only strong owner reference */
	Perl_vivify_defelem(aTHX_ delegate);
	int leaked = SvROK(weak) ? 1 : 0;
	printf("resolved=%d target_null=%d owner_alive=%d\n",
		LvTARGLEN(delegate) == 0, LvTARG(delegate) == NULL, leaked);
	/* Release the leaked reference explicitly so this diagnostic exits cleanly. */
	if (leaked) SvREFCNT_dec(owner);
	SvREFCNT_dec(delegate);
	SvREFCNT_dec(weak);
	PL_perl_destruct_level = 2;
	int status = perl_destruct(interp);
	perl_free(interp);
	PERL_SYS_TERM();
	return status ? 2 : leaked;
}
