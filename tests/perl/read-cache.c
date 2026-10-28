#include "read-cases.h"
#include "hash-iteration.h"

/* Private constructor: inversion lists use the PV layout but are native
 * regex data, and copying them must preserve their inversion-list type. */
START_EXTERN_C
PERL_CALLCONV SV *Perl__new_invlist(pTHX_ IV initial_size);
END_EXTERN_C

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	SV *native = Perl__new_invlist(aTHX_ 0);
	SV *native_copy = newSVsv(native);
	CHECK(SvTYPE(native_copy) == SVt_INVLIST);
	SvREFCNT_dec(native_copy);
	SvREFCNT_dec(native);
	read_case tests[read_cases];
	SV *alias;
	build_cases(aTHX_ tests, &alias);
	for (int pass = 0; pass < 3; pass++) {
		ENTER;
		SAVETMPS;
		for (int i = 0; i < read_cases; i++) exercise_case(aTHX_ &tests[i]);
		FREETMPS;
		LEAVE;
	}
	for (int i = 0; i < read_cases; i++) SvREFCNT_dec(tests[i].value);
	SvREFCNT_dec(alias);
	hash_state hash;
	build_hash(aTHX_ &hash);
	struct wump_perl_task task = {0};
	task.interp = aTHX;
	task.main = 1;
	Perl_wump_task_activate(aTHX_ &task);
	ENTER;
	SAVETMPS;
	exercise_hash(aTHX_ &hash, TRUE);
	HV *empty = newHV();
	Perl_wump_publish(aTHX_ (SV *)empty);
	hash_state empty_state = {0};
	empty_state.value = empty;
	capture_hash(&empty_state);
	CHECK(hv_iterinit(empty) == 0 && hv_iternext(empty) == NULL);
	unchanged_hash(&empty_state);
	SvREFCNT_dec(empty);
	Perl_wump_elements_clear(aTHX_ &task);
	FREETMPS;
	LEAVE;
	Perl_wump_task_activate(aTHX_ NULL);
	unchanged_hash(&hash);
	SvREFCNT_dec(hash.value);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - published scalar reads and copies preserve source caches, dual values, booleans, encoding and COW buffers");
	puts("ok - shared hash iteration and cloning preserve the root cursor and empty hash storage in C/C++");
	return 0;
}
