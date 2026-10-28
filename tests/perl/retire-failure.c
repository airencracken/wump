#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static _Thread_local int reject_record;
static _Thread_local int reject_snapshot;
static SV *target;
static int kind;
extern void *__real_malloc(size_t);
void *__wrap_malloc(size_t size) {
	if (reject_snapshot && size >= 16385) {
		reject_snapshot = 0;
		/* Perl's real system-malloc failure exits the process. Throw here to
		 * test unwinding at the same allocation point after a copy is rooted. */
		Perl_croak_nocontext("injected snapshot allocation exception");
	}
	if (reject_record && size == 2 * sizeof(void *)) {
		reject_record = 0;
		return NULL;
	}
	return __real_malloc(size);
}

static XS(native_snapshot) {
	dXSARGS;
	PERL_UNUSED_ARG(cv);
	PERL_UNUSED_VAR(items);
	reject_snapshot = 1;
	SV *copy = Perl_wump_scalar_snapshot(aTHX_ target);
	reject_snapshot = 0;
	SvREFCNT_dec(copy);
	XSRETURN_EMPTY;
}

static XS(native_write) {
	dXSARGS;
	PERL_UNUSED_ARG(cv);
	PERL_UNUSED_VAR(items);
	reject_record = 1;
	struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ target);
	/* Detachment allocates its ticket before the resource swap. */
	Perl_wump_mutation_end(aTHX_ guard);
	XSRETURN_EMPTY;
}

static XS(native_clone) {
	dXSARGS;
	PERL_UNUSED_ARG(cv);
	PERL_UNUSED_VAR(items);
	PerlInterpreter *copy = perl_clone(aTHX, 0);
	CHECK(copy);
	PERL_SET_CONTEXT(copy);
	CHECK(perl_destruct(copy) == 0);
	perl_free(copy);
	PERL_SET_CONTEXT(aTHX);
	XSRETURN_EMPTY;
}

static void xs_init(pTHX) {
	newXS("NativeFail::write", native_write, __FILE__);
	newXS("NativeFail::clone", native_clone, __FILE__);
	newXS("NativeFail::snapshot", native_snapshot, __FILE__);
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	char program[] = "retire-failure", option[] = "-e", code[] = "0";
	char *args[] = {program, option, code, NULL};
	CHECK(perl_parse(interp, xs_init, 3, args, NULL) == 0);
	struct wump_perl_task task = {0};
	task.interp = aTHX;
	task.main = 1;
	Perl_wump_task_activate(aTHX_ &task);
	for (kind = 0; kind < 3; kind++) {
		ENTER;
		SAVETMPS;
		SV *scalar = NULL;
		AV *array = NULL;
		HV *hash = NULL;
		if (kind == 0) target = scalar = newSVpvs("unchanged borrowed string");
		else if (kind == 1) {
			array = newAV();
			av_push(array, newSViv(19));
			target = (SV *)array;
		} else {
			hash = newHV();
			CHECK(hv_store(hash, "key", 3, newSViv(23), 0));
			target = (SV *)hash;
		}
		Perl_wump_publish(aTHX_ target);
		STRLEN length;
		const char *bytes = scalar ? SvPV_const(scalar, length) : NULL;
		SV **slot = array ? Perl_wump_borrow_av(aTHX_ array, 0) : NULL;
		HE *entry = hash ? Perl_wump_borrow_hv(aTHX_ hash, "key", 3, 0) : NULL;
		void *storage = scalar ? SvANY(scalar) : array ? (void *)AvALLOC(array) : (void *)HvARRAY(hash);
		SV *error = eval_pv("eval { NativeFail::write() }; $@", FALSE);
		reject_record = 0;
		CHECK(strstr(SvPV_nolen(error), "cannot allocate retirement record"));
		error = eval_pv("eval { NativeFail::clone() }; $@", FALSE);
		CHECK(strstr(SvPV_nolen(error), "cannot clone an interpreter with active borrows or mutations"));
		CHECK(storage == (scalar ? SvANY(scalar) : array ? (void *)AvALLOC(array) : (void *)HvARRAY(hash)));
		size_t pins, pending, nodes;
		Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
		CHECK(pins && !pending);
		if (scalar) {
			sv_setpvs(scalar, "replacement");
			CHECK(strEQ(bytes, "unchanged borrowed string"));
		} else if (array) {
			av_clear(array);
			CHECK(SvIV(*slot) == 19);
		} else {
			hv_clear(hash);
			CHECK(SvIV(HeVAL(entry)) == 23);
		}
		SvREFCNT_dec(target);
		FREETMPS;
		LEAVE;
		Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
		CHECK(!pins && !pending);
	}
	ENTER;
	SAVETMPS;
	char *large;
	Newx(large, 16385, char);
	memset(large, 'x', 16384);
	large[16384] = '\0';
	target = newSVpvn(large, 16384);
	Safefree(large);
	Perl_wump_publish(aTHX_ target);
	void *original_body = SvANY(target);
	const char *original_buffer = SvPVX_const(target);
	IV settled_heads = 0;
	for (int pass = 0; pass < 3; pass++) {
		ENTER;
		SAVETMPS;
		SV *error = eval_pv("eval { NativeFail::snapshot() }; $@", FALSE);
		reject_snapshot = 0;
		CHECK(strstr(SvPV_nolen(error), "injected snapshot allocation exception"));
		FREETMPS;
		LEAVE;
		if (!pass) settled_heads = PL_sv_count;
		else CHECK(PL_sv_count == settled_heads);
	}
	CHECK(SvANY(target) == original_body && SvPVX_const(target) == original_buffer);
	size_t pins, pending, nodes;
	Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
	CHECK(!pins && !pending);
	struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ target);
	CHECK(guard);
	SV *snapshot = Perl_wump_scalar_snapshot(aTHX_ target);
	CHECK(SvCUR(snapshot) == 16384 && memEQ(SvPVX_const(snapshot), original_buffer, 16384));
	SvREFCNT_dec(snapshot);
	Perl_wump_mutation_end(aTHX_ guard);
	SvREFCNT_dec(target);
	FREETMPS;
	LEAVE;
	Perl_wump_task_activate(aTHX_ NULL);
	/* A quiescent clone gets its own domain and recognizes copied markers. */
	SV *published = get_sv("NativeFail::published", GV_ADD);
	sv_setpvs(published, "clone domain");
	Perl_wump_publish(aTHX_ published);
	PerlInterpreter *copy = perl_clone(aTHX, 0);
	CHECK(copy);
	PERL_SET_CONTEXT(copy);
	{
		dTHXa(copy);
		SV *cloned = get_sv("NativeFail::published", 0);
		CHECK(cloned && cloned != published && Perl_wump_is_shared(aTHX_ cloned));
		PL_perl_destruct_level = 2;
		CHECK(perl_destruct(copy) == 0);
	}
	perl_free(copy);
	PERL_SET_CONTEXT(interp);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - failed retirement allocation preserves scalar/array/hash storage, releases writer claims, and permits retry");
	puts("ok - a snapshot allocation exception releases its capture and partial copy, preserving source storage and future writes");
	return 0;
}
