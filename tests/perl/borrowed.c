#include "EXTERN.h"
#include "perl.h"
#include <stdio.h>
#include <stdlib.h>

START_EXTERN_C
extern SV *Perl_sv_setsv_cow(pTHX_ SV *, SV *);
END_EXTERN_C

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	struct wump_perl_task task = {0};
	task.interp = aTHX;
	task.main = 1;
	Perl_wump_task_activate(aTHX_ &task);
	ENTER;
	SAVETMPS;
	const char original[] = "original cached data with enough capacity for in-place replacement";
	SV *value = newSVpvn(original, sizeof(original) - 1);
	Perl_wump_publish(aTHX_ value);
	STRLEN length;
	const char *before = SvPV_const(value, length);
	void *body = SvANY(value);
	sv_setpvs(value, "new data");
	CHECK(length == sizeof(original) - 1 && memEQ(before, original, length));
	CHECK(SvANY(value) != body);
	CHECK(((XPVMG *)body)->xpv_cur == sizeof(original) - 1);
	CHECK(strEQ(SvPV_nolen(value), "new data"));
	const char *second = SvPV_const(value, length);
	sv_chop(value, second + 4);
	CHECK(strEQ(SvPV_nolen(value), "data"));
	CHECK(strEQ(second, "new data"));
	sv_catpvn(value, before, 8);
	CHECK(strEQ(SvPV_nolen(value), "dataoriginal"));
	CHECK(memEQ(before, original, sizeof(original) - 1));
	AV *array = newAV();
	av_push(array, newSViv(17));
	Perl_wump_publish(aTHX_ (SV *)array);
	CHECK(Perl_wump_borrow_av(aTHX_ array, -1) != NULL);
	CHECK(Perl_wump_borrow_av(aTHX_ array, -2) == NULL);
	CHECK(Perl_wump_borrow_av(aTHX_ array, 1) == NULL);
	SvREFCNT_dec(array);
	HV *hash = newHV();
	Perl_wump_publish(aTHX_ (SV *)hash);
	CHECK(Perl_wump_borrow_hv(aTHX_ hash, "absent", 6, 0) == NULL);
	SvREFCNT_dec(hash);
	SvREFCNT_dec(value);
	FREETMPS;
	LEAVE;
	size_t pins, pending, nodes;
	Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
	CHECK(!pins && !pending);
	/* Saturation must deep-copy, including when replacing an existing PV. */
	SV *source = newSVpvs("COW counter saturation requires enough spare space for its byte counter");
	(void)SvGROW(source, SvCUR(source) + 8);
	SV *aliases[300];
	for (int i = 0; i < 300; i++) {
		SV *destination = i & 1 ? newSVpvs("existing destination buffer") : NULL;
		aliases[i] = Perl_sv_setsv_cow(aTHX_ destination, source);
		CHECK(strEQ(SvPV_nolen(aliases[i]), SvPV_nolen(source)));
	}
	for (int i = 0; i < 300; i++) SvREFCNT_dec(aliases[i]);
	SvREFCNT_dec(source);
	Perl_wump_task_activate(aTHX_ NULL);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - a cached PV and its original scalar body survive replacement until the caller's temporary scope ends");
	return 0;
}
