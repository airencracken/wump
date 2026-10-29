/* Minimal embedding reproducer: resolving a delegate must retain its cell
 * before releasing its sole array owner. No Wump APIs or runtime required. */
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
	char program[] = "deferred-target", option[] = "-e", code[] = "0";
	char *embedding[] = {program, option, code, NULL};
	if (perl_parse(interp, NULL, 3, embedding, NULL)) return 2;
	dTHXa(interp);
	AV *owner = newAV();
	SV *cell = newSViv(40);
	av_push(owner, cell);
	SV *weak = newRV_inc(cell);
	sv_rvweaken(weak);
	SV *delegate = Perl_newSVavdefelem(aTHX_ owner, 0, TRUE);
	SvREFCNT_dec(owner); /* delegate alone owns the array, which alone owns cell */
	SV *target = Perl_defelem_target(aTHX_ delegate, NULL);
	int lost = !SvROK(weak);
	printf("resolved=%d target_alive=%d\n", LvTARGLEN(delegate) == 0, !lost);
	if (lost) {
		/* The returned target is dead. Never consume it or decrement it again. */
		LvTARG(delegate) = NULL;
	} else if (SvIV(target) != 40) return 2;
	SvREFCNT_dec(delegate);
	SvREFCNT_dec(weak);
	PL_perl_destruct_level = 2;
	int status = perl_destruct(interp);
	perl_free(interp);
	PERL_SYS_TERM();
	return status ? 2 : lost;
}
