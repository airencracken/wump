#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
START_EXTERN_C
extern OP *Perl_pp_rv2av(pTHX);
extern OP *Perl_pp_rv2sv(pTHX);
extern OP *Perl_pp_multideref(pTHX);
extern SV *__real_Perl_wump_load_rv(pTHX_ SV *, svtype, bool *);
END_EXTERN_C

/* Nine cases replace six; keep the original aggregate coverage per case. */
enum { workers = 8, rounds = 192 };
static bool unguarded;
static bool unguarded_scalar;
typedef struct fixture {
	PerlInterpreter *interp;
	SV *array_source, *hash_source;
	SV *scalar_source, *vivify_source, *chain_source;
	CV *entry;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
} fixture;
typedef struct request { fixture *f; int kind; bool lvalue; unsigned captures; } request;
#ifdef __cplusplus
static thread_local request *current_request;
#else
static _Thread_local request *current_request;
#endif

static void meet(fixture *f) {
	int status = pthread_barrier_wait(&f->barrier);
	CHECK(status == 0 || status == PTHREAD_BARRIER_SERIAL_THREAD);
}

START_EXTERN_C
SV *__wrap_Perl_wump_load_rv(pTHX_ SV *source, svtype type, bool *handled) {
	SV *loaded;
	if (unguarded || (unguarded_scalar && type == SVt_PV)) {
		loaded = SvRV(source);
		*handled = TRUE;
	} else loaded = __real_Perl_wump_load_rv(aTHX_ source, type, handled);
	CHECK(*handled && loaded);
	CHECK(WUMP_REFCNT_LOAD(loaded) >= 2 && "extracted referent must have a lifetime reference");
	request *req = current_request;
	if (++req->captures == 1) {
		meet(req->f); /* Initial extraction has ended all of its claims. */
		meet(req->f); /* Writer has replaced the source and dropped its referent. */
	}
	return loaded;
}
END_EXTERN_C

XS_INTERNAL(execute_reference) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	CHECK(!items);
	request *req = current_request;
	fixture *f = req->f;
	UNOP_AUX op;
	Zero(&op, 1, UNOP_AUX);
	UNOP_AUX_item aux[3];
	Zero(aux, 3, UNOP_AUX_item);
	OP *entry = (OP *)&op;
	entry->op_flags = OPf_WANT_SCALAR | (req->lvalue ? OPf_MOD : 0);
	OP *previous = PL_op;
	SSize_t stack_mark = SP - PL_stack_base;
	EXTEND(SP, 1);
	bool hash = req->kind < 6 && req->kind % 2;
	SV *source = req->kind == 6 ? f->scalar_source
		: req->kind == 7 ? f->vivify_source : req->kind == 8 ? f->chain_source
		: hash ? f->hash_source : f->array_source;
	if (req->kind >= 6) {
		entry->op_type = OP_RV2SV;
		entry->op_ppaddr = Perl_pp_rv2sv;
		if (req->kind == 7) {
			entry->op_flags |= OPf_MOD;
			entry->op_private = OPpDEREF_AV;
		}
		PUSHs(source);
	} else if (req->kind < 2) {
		entry->op_type = hash ? OP_RV2HV : OP_RV2AV;
		entry->op_flags |= OPf_REF;
		entry->op_ppaddr = Perl_pp_rv2av;
		PUSHs(source);
	} else {
		entry->op_type = OP_MULTIDEREF;
		entry->op_ppaddr = Perl_pp_multideref;
		op.op_aux = aux;
		UV action;
		int at;
		if (req->kind < 4) {
			action = hash ? MDEREF_HV_padsv_vivify_rv2hv_helem : MDEREF_AV_padsv_vivify_rv2av_aelem;
			aux[1].pad_offset = hash ? 5 : 1;
			at = 2;
		} else {
			action = hash ? MDEREF_HV_pop_rv2hv_helem : MDEREF_AV_pop_rv2av_aelem;
			PUSHs(source);
			at = 1;
		}
		aux[0].uv = action | MDEREF_INDEX_const | MDEREF_FLAG_last;
		if (hash) aux[at].pad_offset = 3;
		else aux[at].iv = 0;
	}
	PUTBACK;
	PL_op = entry;
	CHECK(entry->op_ppaddr(aTHX) == NULL);
	SV *loaded = *PL_stack_sp;
	if (req->kind == 8) {
		CHECK(entry->op_ppaddr(aTHX) == NULL);
		CHECK(req->captures == 2);
		loaded = *PL_stack_sp;
	}
	if (req->kind == 7) {
		CHECK(SvROK(loaded) && SvTYPE(SvRV(loaded)) == SVt_PVAV);
		CHECK(Perl_wump_is_shared(aTHX_ SvRV(loaded)));
		CHECK(av_store((AV *)SvRV(loaded), 0, newSViv(42)));
		loaded = *av_fetch((AV *)SvRV(loaded), 0, 0);
	}
	if (req->kind == 0) loaded = *av_fetch((AV *)loaded, 0, 0);
	else if (req->kind == 1) loaded = *hv_fetch((HV *)loaded, "key", 3, 0);
	CHECK(SvIV(loaded) == 42);
	PL_stack_sp = PL_stack_base + stack_mark;
	PL_op = previous;
	XSRETURN_EMPTY;
}

static SV *make_array(pTHX_ IV value) {
	AV *av = newAV();
	CHECK(av_store(av, 0, newSViv(value)));
	return (SV *)av;
}
static SV *make_hash(pTHX_ IV value) {
	HV *hv = newHV();
	CHECK(hv_store(hv, "key", 3, newSViv(value), 0));
	return (SV *)hv;
}

typedef struct argument { fixture *f; int id; GV *error; COP *cop; HV *stash; } argument;
static void drop_stacks(pTHX) {
	while (PL_curstackinfo->si_next) PL_curstackinfo = PL_curstackinfo->si_next;
	while (PL_curstackinfo) {
		PERL_SI *si = PL_curstackinfo;
		PL_curstackinfo = si->si_prev;
		SvREFCNT_dec(si->si_stack);
		Safefree(si->si_cxstack);
		Safefree(si);
	}
	Safefree(PL_tmps_stack); Safefree(PL_markstack); Safefree(PL_scopestack);
#ifdef DEBUGGING
	Safefree(PL_scopestack_name);
#endif
	Safefree(PL_savestack);
}

static void *exercise(void *arg) {
	argument *ctx = (argument *)arg;
	fixture *f = ctx->f;
	dTHXa(f->interp);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ &f->pools[ctx->id]);
	struct wump_perl_task task = {0};
	task.interp = aTHX; task.Ierrgv = ctx->error;
	task.Icurcop = ctx->cop; task.Icurstash = ctx->stash;
	Perl_wump_task_activate(aTHX_ &task);
	JMPENV_BOOTSTRAP;
	init_stacks();
	task.initialized = 1;
	SV *key = newSVpvs("key"); SvUPGRADE(key, SVt_PVMG);
	SV *pad[6] = {NULL, f->array_source, NULL, key, NULL, f->hash_source};
	PL_curpad = pad;
	request req = {f, 0, FALSE, 0}; current_request = &req;
	for (int pass = 0; pass < rounds; pass++) {
		ENTER; SAVETMPS;
		if (!ctx->id) {
			sv_setrv_noinc(f->array_source, make_array(aTHX_ 42));
			sv_setrv_noinc(f->hash_source, make_hash(aTHX_ 42));
			sv_setrv_noinc(f->scalar_source, newSViv(42));
			sv_setrv_noinc(f->vivify_source, newSV(0));
			sv_setrv_noinc(f->chain_source, newRV_noinc(newSViv(42)));
		}
		meet(f);
		if (!ctx->id) {
			meet(f);
			size_t pins, pending, nodes;
			Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
			CHECK(!pins && !pending);
			sv_setrv_noinc(f->array_source, make_array(aTHX_ 99));
			sv_setrv_noinc(f->hash_source, make_hash(aTHX_ 99));
			sv_setrv_noinc(f->scalar_source, newSViv(99));
			sv_setrv_noinc(f->vivify_source, newSV(0));
			sv_setrv_noinc(f->chain_source, newRV_noinc(newSViv(99)));
			meet(f);
		} else {
			req.kind = (pass / 2 + ctx->id) % 9;
			req.lvalue = pass % 2;
			req.captures = 0;
			dSP; PUSHMARK(SP); PUTBACK;
			call_sv((SV *)f->entry, G_DISCARD | G_EVAL);
			CHECK(!SvTRUE(ERRSV));
		}
		FREETMPS; LEAVE;
		meet(f);
		if (!ctx->id) {
			size_t pins, pending, nodes;
			Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
			CHECK(!pins && !pending);
		}
		meet(f);
	}
	SvREFCNT_dec(key); SvREFCNT_dec(ctx->error);
	drop_stacks(aTHX);
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

int main(int argc, char **argv, char **env) {
	unguarded = argc == 2 && strEQ(argv[1], "--unguarded");
	unguarded_scalar = argc == 2 && strEQ(argv[1], "--unguarded-scalar");
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc(); CHECK(interp);
	PERL_SET_CONTEXT(interp); perl_construct(interp);
	char program[] = "opcode-references", option[] = "-e", code[] = "0";
	char *embedding[] = {program, option, code, NULL};
	CHECK(perl_parse(interp, NULL, 3, embedding, NULL) == 0);
	dTHXa(interp);
	fixture f = {0}; f.interp = aTHX;
	f.array_source = newRV_noinc(make_array(aTHX_ 42));
	f.hash_source = newRV_noinc(make_hash(aTHX_ 42));
	f.scalar_source = newRV_noinc(newSViv(42));
	f.vivify_source = newRV_noinc(newSV(0));
	f.chain_source = newRV_noinc(newRV_noinc(newSViv(42)));
	Perl_wump_publish(aTHX_ f.array_source); Perl_wump_publish(aTHX_ f.hash_source);
	Perl_wump_publish(aTHX_ f.scalar_source); Perl_wump_publish(aTHX_ f.vivify_source);
	Perl_wump_publish(aTHX_ f.chain_source);
	f.entry = newXS("ReferenceFixture::invoke", execute_reference, __FILE__);
	Perl_wump_publish(aTHX_ (SV *)f.entry);
	CHECK(pthread_barrier_init(&f.barrier, NULL, workers) == 0);
	pthread_t threads[workers]; argument args[workers];
	for (int id = 0; id < workers; id++) {
		Perl_wump_allocator_init(aTHX_ &f.pools[id]);
		args[id].f = &f; args[id].id = id;
		args[id].cop = PL_curcop; args[id].stash = PL_curstash;
		args[id].error = (GV *)newSV(0);
		gv_init(args[id].error, NULL, "__reference_error", 17, 0);
		GvSV(args[id].error) = newSVpvs("");
		CHECK(pthread_create(&threads[id], NULL, exercise, &args[id]) == 0);
	}
	for (int id = 0; id < workers; id++) CHECK(pthread_join(threads[id], NULL) == 0);
	for (int id = 0; id < workers; id++) Perl_wump_allocator_merge(aTHX_ &f.pools[id]);
	CHECK(pthread_barrier_destroy(&f.barrier) == 0);
	SvREFCNT_dec(f.array_source); SvREFCNT_dec(f.hash_source);
	SvREFCNT_dec(f.scalar_source); SvREFCNT_dec(f.vivify_source); SvREFCNT_dec(f.chain_source);
	PL_perl_destruct_level = 2; CHECK(perl_destruct(interp) == 0);
	perl_free(interp); PERL_SYS_TERM();
	puts("ok - seven readers complete 1344 scalar/aggregate dereference invocations across 1920 source RV replacements");
	puts("ok - nested scalar dereferences and scalar lvalue vivification retain and publish their original targets");
	puts("ok - captures release exclusion before the writer replaces the source and retain the original referent until use");
	return 0;
}
