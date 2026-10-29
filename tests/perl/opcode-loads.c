#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
START_EXTERN_C
extern OP *Perl_pp_aelemfast(pTHX);
extern OP *Perl_pp_aelem(pTHX);
extern OP *Perl_pp_helem(pTHX);
extern OP *Perl_pp_multideref(pTHX);
extern SV *__real_Perl_wump_load_av(pTHX_ AV *, SSize_t, bool *);
extern SV *__real_Perl_wump_load_hv(pTHX_ HV *, SV *, bool *);
END_EXTERN_C

enum { workers = 8, rounds = 256 };
static bool unguarded;
START_EXTERN_C
SV *__wrap_Perl_wump_load_av(pTHX_ AV *av, SSize_t index, bool *handled) {
	if (unguarded) { *handled = FALSE; return NULL; }
	return __real_Perl_wump_load_av(aTHX_ av, index, handled);
}
SV *__wrap_Perl_wump_load_hv(pTHX_ HV *hv, SV *key, bool *handled) {
	if (unguarded) { *handled = FALSE; return NULL; }
	return __real_Perl_wump_load_hv(aTHX_ hv, key, handled);
}
END_EXTERN_C

typedef struct fixture {
	PerlInterpreter *interp;
	AV *av;
	HV *hv;
	CV *entry;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
} fixture;
typedef struct request { fixture *f; int kind; bool lvalue; } request;
#ifdef __cplusplus
static thread_local request *current_request;
#else
static _Thread_local request *current_request;
#endif

static void meet(fixture *f) {
	int status = pthread_barrier_wait(&f->barrier);
	CHECK(status == 0 || status == PTHREAD_BARRIER_SERIAL_THREAD);
}

XS_INTERNAL(execute_load) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	CHECK(!items);
	request *req = current_request;
	fixture *f = req->f;
	union { PADOP pad; UNOP_AUX multi; } op;
	memset(&op, 0, sizeof(op));
	UNOP_AUX_item aux[3];
	Zero(aux, 3, UNOP_AUX_item);
	OP *entry = (OP *)&op;
	entry->op_flags = OPf_WANT_SCALAR | (req->lvalue ? OPf_MOD : 0);
	OP *previous = PL_op;
	SSize_t stack_mark = SP - PL_stack_base;
	EXTEND(SP, 2);
	switch (req->kind) {
	case 0:
		entry->op_type = OP_AELEMFAST_LEX;
		entry->op_targ = 1;
		entry->op_ppaddr = Perl_pp_aelemfast;
		break;
	case 1:
		entry->op_type = OP_AELEMFAST;
		op.pad.op_padix = 2;
		entry->op_ppaddr = Perl_pp_aelemfast;
		break;
	case 2:
		entry->op_type = OP_AELEM;
		entry->op_ppaddr = Perl_pp_aelem;
		PUSHs((SV *)f->av); PUSHs(PL_curpad[4]);
		break;
	case 3:
		entry->op_type = OP_HELEM;
		entry->op_ppaddr = Perl_pp_helem;
		PUSHs((SV *)f->hv); PUSHs(PL_curpad[3]);
		break;
	default:
		entry->op_type = OP_MULTIDEREF;
		entry->op_ppaddr = Perl_pp_multideref;
		op.multi.op_aux = aux;
		aux[0].uv = (req->kind == 4 ? MDEREF_AV_padav_aelem : MDEREF_HV_padhv_helem)
			| MDEREF_INDEX_const | MDEREF_FLAG_last;
		aux[1].pad_offset = req->kind == 4 ? 1 : 5;
		if (req->kind == 4) aux[2].iv = 0;
		else aux[2].pad_offset = 3;
	}
	PUTBACK;
	PL_op = entry;
	CHECK(entry->op_ppaddr(aTHX) == NULL);
	SV *loaded = *PL_stack_sp;
	CHECK(WUMP_REFCNT_LOAD(loaded) >= 2 && "loaded element must have a lifetime reference");
	meet(f); /* Every reader has completed lookup; no caller-held claim. */
	if (req->kind == 5) CHECK(PL_multideref_pc == &aux[2]);
	meet(f); /* Writer has now removed the container's ownership. */
	CHECK(SvIV(loaded) == 42);
	PL_stack_sp = PL_stack_base + stack_mark;
	PL_op = previous;
	XSRETURN_EMPTY;
}

typedef struct argument { fixture *f; int id; GV *error, *array_glob; COP *cop; HV *stash; } argument;

static void drop_stacks(pTHX) {
	while (PL_curstackinfo->si_next) PL_curstackinfo = PL_curstackinfo->si_next;
	while (PL_curstackinfo) {
		PERL_SI *si = PL_curstackinfo;
		PL_curstackinfo = si->si_prev;
		SvREFCNT_dec(si->si_stack);
		Safefree(si->si_cxstack);
		Safefree(si);
	}
	Safefree(PL_tmps_stack);
	Safefree(PL_markstack);
	Safefree(PL_scopestack);
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
	task.interp = aTHX;
	task.Ierrgv = ctx->error;
	task.Icurcop = ctx->cop;
	task.Icurstash = ctx->stash;
	Perl_wump_task_activate(aTHX_ &task);
	JMPENV_BOOTSTRAP;
	init_stacks();
	task.initialized = 1;
	SV *key = newSVpvs("key");
	SvUPGRADE(key, SVt_PVMG);
	SV *pad[6] = {NULL, (SV *)f->av, (SV *)ctx->array_glob, key, newSViv(0), (SV *)f->hv};
	PL_curpad = pad;
	request req = {f, 0, FALSE};
	current_request = &req;
	for (int pass = 0; pass < rounds; pass++) {
		ENTER;
		SAVETMPS;
		if (!ctx->id) {
			CHECK(av_store(f->av, 0, newSViv(42)));
			CHECK(hv_store(f->hv, "key", 3, newSViv(42), 0));
		}
		meet(f);
		if (!ctx->id) {
			meet(f);
			size_t pins, pending, nodes;
			Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
			CHECK(!pins && !pending);
			/* Both deletion and whole-table retirement must leave captured
			 * element heads intact. A head pin needs no retired table. */
			if (pass % 2) {
				av_clear(f->av); hv_clear(f->hv);
				av_extend(f->av, 1024);
			} else {
				av_delete(f->av, 0, G_DISCARD);
				hv_delete(f->hv, "key", 3, G_DISCARD);
			}
			meet(f);
		} else {
			req.kind = (pass / 2 + ctx->id) % 6;
			req.lvalue = pass % 2;
			dSP;
			PUSHMARK(SP); PUTBACK;
			call_sv((SV *)f->entry, G_DISCARD | G_EVAL);
			CHECK(!SvTRUE(ERRSV));
		}
		FREETMPS;
		LEAVE;
		meet(f);
		if (!ctx->id) {
			size_t pins, pending, nodes;
			Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
			CHECK(!pins && !pending);
		}
		meet(f);
	}
	SvREFCNT_dec(key);
	SvREFCNT_dec(pad[4]);
	SvREFCNT_dec(ctx->array_glob);
	SvREFCNT_dec(ctx->error);
	drop_stacks(aTHX);
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

int main(int argc, char **argv, char **env) {
	unguarded = argc == 2 && strEQ(argv[1], "--unguarded");
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	char program[] = "opcode-loads", option[] = "-e", code[] = "0";
	char *embedding[] = {program, option, code, NULL};
	CHECK(perl_parse(interp, NULL, 3, embedding, NULL) == 0);
	dTHXa(interp);
	fixture f = {0};
	f.interp = aTHX;
	f.av = newAV(); f.hv = newHV();
	Perl_wump_publish(aTHX_ (SV *)f.av);
	Perl_wump_publish(aTHX_ (SV *)f.hv);
	f.entry = newXS("LoadFixture::invoke", execute_load, __FILE__);
	/* Runtime spawn publishes its entry graph before scheduling any act.
	 * Do the same before these native callers can inspect CV flags. */
	Perl_wump_publish(aTHX_ (SV *)f.entry);
	CHECK(Perl_wump_is_shared(aTHX_ (SV *)f.entry));
	CHECK(pthread_barrier_init(&f.barrier, NULL, workers) == 0);
	pthread_t threads[workers];
	argument args[workers];
	for (int id = 0; id < workers; id++) {
		Perl_wump_allocator_init(aTHX_ &f.pools[id]);
		args[id].f = &f; args[id].id = id;
		args[id].cop = PL_curcop; args[id].stash = PL_curstash;
		args[id].error = (GV *)newSV(0);
		gv_init(args[id].error, NULL, "__load_error", 12, 0);
		GvSV(args[id].error) = newSVpvs("");
		args[id].array_glob = (GV *)newSV(0);
		gv_init(args[id].array_glob, NULL, "__load_array", 12, 0);
		GvAV(args[id].array_glob) = (AV *)SvREFCNT_inc(f.av);
		CHECK(pthread_create(&threads[id], NULL, exercise, &args[id]) == 0);
	}
	for (int id = 0; id < workers; id++) CHECK(pthread_join(threads[id], NULL) == 0);
	for (int id = 0; id < workers; id++) Perl_wump_allocator_merge(aTHX_ &f.pools[id]);
	CHECK(pthread_barrier_destroy(&f.barrier) == 0);
	SvREFCNT_dec(f.av); SvREFCNT_dec(f.hv);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - seven readers retain 896 read-only and 896 writable opcode results across concurrent container deletion and clearing");
	puts("ok - multideref diagnostic cursors remain local to each executor");
	puts("ok - each round releases all storage pins and retired tables");
	return 0;
}
