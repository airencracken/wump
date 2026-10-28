#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
START_EXTERN_C
extern OP *Perl_pp_preinc(pTHX);
extern OP *Perl_pp_predec(pTHX);
extern OP *Perl_pp_postinc(pTHX);
extern OP *Perl_pp_postdec(pTHX);
extern OP *Perl_pp_add(pTHX);
extern OP *Perl_pp_subtract(pTHX);
extern OP *Perl_pp_i_add(pTHX);
extern OP *Perl_pp_i_subtract(pTHX);
extern OP *Perl_wump_write_impl_preinc(pTHX);
END_EXTERN_C

enum { workers = 8, rounds = 256 };
typedef struct fixture {
	PerlInterpreter *interp;
	SV *value;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
} fixture;
typedef struct argument { fixture *f; int id; } argument;

static void publish_fast_leaf(pTHX_ SV *value) {
	/* These scalar leaves have no outgoing edges. Register their heads
	 * directly so publication magic does not divert the opcode fast paths
	 * into already-guarded C APIs. The normal Perl tests use real publication. */
	SvUPGRADE(value, SVt_PVMG);
	Perl_wump_memory_mark(aTHX_ value, 2);
	CHECK(!SvMAGICAL(value));
}

static void invoke(pTHX_ SV *value, int type, SV *operand, bool unguarded) {
	OP op;
	Zero(&op, 1, OP);
	op.op_type = type;
	op.op_targ = 1;
	op.op_flags = OPf_WANT_SCALAR | (operand ? OPf_STACKED : 0);
	switch (type) {
	case OP_PREINC: op.op_ppaddr = unguarded ? Perl_wump_write_impl_preinc : Perl_pp_preinc; break;
	case OP_PREDEC: op.op_ppaddr = Perl_pp_predec; break;
	case OP_POSTINC: op.op_ppaddr = Perl_pp_postinc; break;
	case OP_POSTDEC: op.op_ppaddr = Perl_pp_postdec; break;
	case OP_ADD: op.op_ppaddr = Perl_pp_add; break;
	case OP_SUBTRACT: op.op_ppaddr = Perl_pp_subtract; break;
	case OP_I_ADD: op.op_ppaddr = Perl_pp_i_add; break;
	case OP_I_SUBTRACT: op.op_ppaddr = Perl_pp_i_subtract; break;
	default: abort();
	}
	PL_op = &op;
	dSP;
	SSize_t mark = SP - PL_stack_base;
	EXTEND(SP, 2);
	PUSHs(value);
	if (operand) PUSHs(operand);
	PUTBACK;
	CHECK(op.op_ppaddr(aTHX) == NULL);
	PL_stack_sp = PL_stack_base + mark;
	PL_op = NULL;
}

static void rendezvous(fixture *f) {
	int result = pthread_barrier_wait(&f->barrier);
	CHECK(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD);
}

static void drop_stacks(pTHX) {
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
	Perl_wump_task_activate(aTHX_ &task);
	JMPENV_BOOTSTRAP;
	init_stacks();
	task.initialized = 1;
	SV *pad[2] = {NULL, newSV(0)};
	PL_curpad = pad;
	SV *operand = newSViv(2);
	struct wump_mutation *held = NULL;
	if (!ctx->id) held = Perl_wump_mutation_begin(aTHX_ f->value);
	rendezvous(f);
	struct wump_shared *claim = NULL;
	if (ctx->id) {
		CHECK(!Perl_wump_read_try_begin(aTHX_ f->value, &claim) && !claim);
		bool busy = FALSE;
		CHECK(!Perl_wump_mutation_try_begin(aTHX_ f->value, &busy) && busy);
	} else {
		CHECK(held && Perl_wump_read_try_begin(aTHX_ f->value, &claim) && !claim);
	}
	rendezvous(f);
	if (held) Perl_wump_mutation_end(aTHX_ held);
	rendezvous(f);
	for (int pass = 0; pass < rounds; pass++) {
		ENTER;
		SAVETMPS;
		if (ctx->id < 2) {
			bool busy;
			struct wump_mutation *guard;
			do {
				guard = Perl_wump_mutation_try_begin(aTHX_ f->value, &busy);
				if (busy) sched_yield();
			} while (busy);
			CHECK(guard);
			invoke(aTHX_ f->value, OP_PREINC, NULL, FALSE);
			invoke(aTHX_ f->value, OP_PREDEC, NULL, FALSE);
			invoke(aTHX_ f->value, OP_POSTINC, NULL, FALSE);
			invoke(aTHX_ f->value, OP_POSTDEC, NULL, FALSE);
			invoke(aTHX_ f->value, OP_ADD, operand, FALSE);
			invoke(aTHX_ f->value, OP_SUBTRACT, operand, FALSE);
			invoke(aTHX_ f->value, OP_I_ADD, operand, FALSE);
			invoke(aTHX_ f->value, OP_I_SUBTRACT, operand, FALSE);
			CHECK(SvIV(f->value) == 42 && SvTRUE(f->value));
			Perl_wump_mutation_end(aTHX_ guard);
		} else {
			while (!Perl_wump_read_try_begin(aTHX_ f->value, &claim)) sched_yield();
			CHECK(claim);
			CHECK(SvIV(f->value) == 42 && SvIV_nomg(f->value) == 42);
			CHECK(SvUV(f->value) == 42 && SvUV_nomg(f->value) == 42);
			CHECK(SvNV(f->value) == 42 && SvNV_nomg(f->value) == 42);
			CHECK(SvTRUE(f->value) && SvTRUE_nomg(f->value));
			SV *copy = newSVsv(f->value);
			CHECK(SvIV(copy) == 42);
			SvREFCNT_dec(copy);
			STRLEN byte_length, utf8_length;
			const char *bytes = SvPVbyte(f->value, byte_length);
			const char *utf8 = SvPVutf8(f->value, utf8_length);
			Perl_wump_read_end(aTHX_ claim);
			sched_yield();
			CHECK(byte_length == 2 && memEQ(bytes, "42", 2));
			CHECK(utf8_length == 2 && memEQ(utf8, "42", 2));
		}
		FREETMPS;
		LEAVE;
	}
	SvREFCNT_dec(operand);
	SvREFCNT_dec(pad[1]);
	PL_curpad = NULL;
	drop_stacks(aTHX);
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	struct wump_perl_task main_task = {0};
	main_task.interp = aTHX;
	main_task.main = 1;
	Perl_wump_task_activate(aTHX_ &main_task);
	ENTER;
	SAVETMPS;
	SV **original_pad = PL_curpad;
	SV *pad[2] = {NULL, newSV(0)};
	PL_curpad = pad;
	SV *number = newSViv(42);
	publish_fast_leaf(aTHX_ number);
	STRLEN length;
	const char *computed = SvPV_const(number, length);
	void *body = SvANY(number);
	invoke(aTHX_ number, OP_PREINC, NULL, argc == 2 && strEQ(argv[1], "--unguarded"));
	CHECK(SvANY(number) != body);
	CHECK(((XPVIV *)body)->xiv_iv == 42);
	CHECK(SvIV(number) == 43 && length == 2 && memEQ(computed, "42", 2));
	SvREFCNT_dec(number);
	SV *text = newSVpvs("Az");
	publish_fast_leaf(aTHX_ text);
	const char *cached = SvPV_const(text, length);
	invoke(aTHX_ text, OP_PREINC, NULL, FALSE);
	CHECK(length == 2 && memEQ(cached, "Az", 2));
	CHECK(strEQ(SvPV_nolen(text), "Ba"));
	SvREFCNT_dec(text);
	SvREFCNT_dec(pad[1]);
	PL_curpad = original_pad;
	FREETMPS;
	LEAVE;
	Perl_wump_task_activate(aTHX_ NULL);
	fixture f = {0};
	f.interp = aTHX;
	f.value = newSViv(42);
	publish_fast_leaf(aTHX_ f.value);
	CHECK(pthread_barrier_init(&f.barrier, NULL, workers) == 0);
	pthread_t threads[workers];
	argument args[workers];
	for (int id = 0; id < workers; id++) {
		Perl_wump_allocator_init(aTHX_ &f.pools[id]);
		args[id].f = &f;
		args[id].id = id;
		CHECK(pthread_create(&threads[id], NULL, exercise, &args[id]) == 0);
	}
	for (int id = 0; id < workers; id++) CHECK(pthread_join(threads[id], NULL) == 0);
	for (int id = 0; id < workers; id++) Perl_wump_allocator_merge(aTHX_ &f.pools[id]);
	CHECK(pthread_barrier_destroy(&f.barrier) == 0);
	size_t pins, pending, nodes;
	Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
	CHECK(!pins && !pending);
	SvREFCNT_dec(f.value);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - opcode fast paths preserve borrowed scalar bodies and alphabetic increment buffers");
	puts("ok - 6 readers and 2 writers complete 4096 actual opcode mutations with 1536 concurrent numeric/copy/encoding captures");
	return 0;
}
