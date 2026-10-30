#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
START_EXTERN_C
extern OP *Perl_pp_add(pTHX);
extern OP *Perl_pp_subtract(pTHX);
extern OP *Perl_pp_multiply(pTHX);
extern OP *Perl_pp_divide(pTHX);
extern OP *Perl_pp_modulo(pTHX);
extern OP *Perl_pp_eq(pTHX);
extern OP *Perl_pp_lt(pTHX);
extern OP *Perl_pp_gt(pTHX);
extern OP *Perl_pp_ncmp(pTHX);
extern OP *Perl_pp_seq(pTHX);
extern OP *Perl_pp_sne(pTHX);
extern OP *Perl_pp_scmp(pTHX);
extern OP *Perl_pp_i_add(pTHX);
extern OP *Perl_pp_i_ncmp(pTHX);
extern OP *Perl_wump_read_impl_add(pTHX);
extern OP *Perl_wump_write_impl_add(pTHX);
extern OP *Perl_wump_write_impl_modulo(pTHX);
END_EXTERN_C

enum { workers = 8, rounds = 512 };
typedef struct operation { int type; IV expected; OP *(*function)(pTHX); } operation;
static const operation operations[] = {
	{OP_ADD, 44, Perl_pp_add}, {OP_SUBTRACT, 40, Perl_pp_subtract},
	{OP_MULTIPLY, 84, Perl_pp_multiply}, {OP_DIVIDE, 21, Perl_pp_divide},
	{OP_MODULO, 0, Perl_pp_modulo}, {OP_EQ, 0, Perl_pp_eq},
	{OP_LT, 0, Perl_pp_lt}, {OP_GT, 1, Perl_pp_gt}, {OP_NCMP, 1, Perl_pp_ncmp},
	{OP_SEQ, 0, Perl_pp_seq}, {OP_SNE, 1, Perl_pp_sne}, {OP_SCMP, 1, Perl_pp_scmp},
	{OP_I_ADD, 44, Perl_pp_i_add}, {OP_I_NCMP, 1, Perl_pp_i_ncmp}
};
typedef struct request {
	SV *source, *other;
	const operation *op;
	bool unguarded;
	IV result;
	bool publish_after_classification;
	bool stacked, native_control;
	U32 result_flags;
	SV *result_head;
} request;
#ifdef __cplusplus
static thread_local request *current_request;
static thread_local SV *publish_after_read;
static thread_local unsigned operand_prepares;
static thread_local bool numeric_active;
static thread_local unsigned numeric_allocations;
#else
static _Thread_local request *current_request;
static _Thread_local SV *publish_after_read;
static _Thread_local unsigned operand_prepares;
static _Thread_local bool numeric_active;
static _Thread_local unsigned numeric_allocations;
#endif

START_EXTERN_C
extern void *__real_malloc(size_t);
extern void *__real_calloc(size_t, size_t);
extern void *__real_realloc(void *, size_t);
void *__wrap_malloc(size_t size) {
	if (numeric_active) numeric_allocations++;
	return __real_malloc(size);
}
void *__wrap_calloc(size_t count, size_t size) {
	if (numeric_active) numeric_allocations++;
	return __real_calloc(count, size);
}
void *__wrap_realloc(void *memory, size_t size) {
	if (numeric_active) numeric_allocations++;
	return __real_realloc(memory, size);
}
extern bool __real_Perl_wump_numeric_enter(pTHX_ SV *target);
extern void __real_Perl_wump_numeric_leave(pTHX);
bool __wrap_Perl_wump_numeric_enter(pTHX_ SV *target) {
	bool entered = __real_Perl_wump_numeric_enter(aTHX_ target);
	if (entered) {
		CHECK(!numeric_active);
		numeric_active = TRUE;
		numeric_allocations = 0;
	}
	return entered;
}
void __wrap_Perl_wump_numeric_leave(pTHX) {
	CHECK(numeric_active && !numeric_allocations);
	numeric_active = FALSE;
	__real_Perl_wump_numeric_leave(aTHX);
}
extern struct wump_operands *__real_Perl_wump_operands_begin(pTHX_ SV *target);
struct wump_operands *__wrap_Perl_wump_operands_begin(pTHX_ SV *target) {
	operand_prepares++;
	return __real_Perl_wump_operands_begin(aTHX_ target);
}
extern void __real_Perl_wump_read_end(pTHX_ struct wump_shared *claim);
void __wrap_Perl_wump_read_end(pTHX_ struct wump_shared *claim) {
	__real_Perl_wump_read_end(aTHX_ claim);
	if (publish_after_read) {
		SV *value = publish_after_read;
		publish_after_read = NULL;
		/* This plain scalar has no outgoing graph edges. Complete its
		 * publication precisely after the first input was classified. */
		Perl_wump_memory_mark(aTHX_ value, 2);
	}
}
END_EXTERN_C

XS_INTERNAL(execute_opcode) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	CHECK(!items);
	request *req = current_request;
	OP op;
	Zero(&op, 1, OP);
	op.op_type = req->op->type;
	op.op_flags = OPf_WANT_SCALAR;
	if (req->stacked) op.op_flags |= OPf_STACKED;
	op.op_targ = 1;
	op.op_ppaddr = req->unguarded ? Perl_wump_read_impl_add : req->op->function;
	if (req->native_control)
		op.op_ppaddr = req->op->type == OP_ADD ? Perl_wump_write_impl_add : Perl_wump_write_impl_modulo;
	OP *previous = PL_op;
	PL_op = &op;
	SSize_t stack_mark = SP - PL_stack_base;
	EXTEND(SP, 2);
	PUSHs(req->source);
	PUSHs(req->other);
	PUTBACK;
	if (req->publish_after_classification) publish_after_read = req->source;
	CHECK(op.op_ppaddr(aTHX) == NULL);
	req->result = SvIV(*PL_stack_sp);
	req->result_head = *PL_stack_sp;
	req->result_flags = SvFLAGS(*PL_stack_sp);
	PL_stack_sp = PL_stack_base + stack_mark;
	PL_op = previous;
	XSRETURN_EMPTY;
}

static bool invoke(pTHX_ CV *entry, request *req) {
	current_request = req;
	dSP;
	PUSHMARK(SP);
	PUTBACK;
	call_sv((SV *)entry, G_DISCARD | G_EVAL);
	bool ok = !SvTRUE(ERRSV);
	if (!ok) {
		CHECK(strstr(SvPV_nolen(ERRSV), "read overlaps mutation of a shared value"));
		sv_setpvs(ERRSV, "");
	}
	CHECK(!PL_wump_task->read_frame);
	return ok;
}

typedef struct fixture {
	PerlInterpreter *interp;
	SV *value;
	CV *entry;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
} fixture;
typedef struct argument { fixture *f; int id; GV *error; COP *cop; HV *stash; } argument;

static void publish_fast_leaf(pTHX_ SV *value) {
	SvUPGRADE(value, SVt_PVMG);
	Perl_wump_memory_mark(aTHX_ value, 2);
	CHECK(!SvMAGICAL(value));
}

static void numeric_reset(pTHX_ SV *value, IV number, svtype kind) {
	if (kind == SVt_IV) { sv_setiv(value, number); return; }
	sv_upgrade(value, kind);
	sv_setpvs(value, "stale cache");
	SvUTF8_on(value);
	SvIV_set(value, number);
	SvIOK_on(value);
	if (kind == SVt_PVNV) { SvNV_set(value, (NV)number); SvNOK_on(value); }
}

static void numeric_boundaries(pTHX_ CV *entry, SV **pad) {
	const IV values[] = {0, 1, 2, 96, 97, IV_MAX / 2};
	const svtype kinds[] = {SVt_IV, SVt_PVIV, SVt_PVNV};
	SV *saved_target = pad[1];
	unsigned checks = 0;
	for (unsigned kind_id = 0; kind_id < sizeof(kinds) / sizeof(kinds[0]); kind_id++) {
		for (unsigned operation_id = 0; operation_id < 2; operation_id++) {
			for (unsigned lhs = 0; lhs < sizeof(values) / sizeof(values[0]); lhs++) {
				for (unsigned rhs = 0; rhs < sizeof(values) / sizeof(values[0]); rhs++) {
					if (operation_id && !values[rhs]) continue;
					/* Exercise ordinary targets, compound assignment, and aliases
					 * to either/both inputs. Compare the exact native result head
					 * and flags as well as the number, with identical initial SVs. */
					for (unsigned alias = 0; alias < 4; alias++) {
						if (alias == 3 && lhs != rhs) continue;
						SV *left = newSViv(values[lhs]), *right = newSViv(values[rhs]);
						SV *target = newSViv(0);
						numeric_reset(aTHX_ left, values[lhs], kinds[kind_id]);
						numeric_reset(aTHX_ right, values[rhs], kinds[kind_id]);
						numeric_reset(aTHX_ target, 0, kinds[kind_id]);
						pad[1] = alias == 0 ? target : alias == 2 ? right : left;
						request req = {0};
						req.source = left;
						req.other = alias == 3 ? left : right;
						req.op = &operations[operation_id ? 4 : 0];
						req.stacked = alias == 1;
						req.native_control = TRUE;
						CHECK(invoke(aTHX_ entry, &req));
						IV expected = req.result;
						U32 expected_flags = req.result_flags;
						CHECK(req.result_head == pad[1]);
						numeric_reset(aTHX_ left, values[lhs], kinds[kind_id]);
						numeric_reset(aTHX_ right, values[rhs], kinds[kind_id]);
						numeric_reset(aTHX_ target, 0, kinds[kind_id]);
						req.native_control = FALSE;
						operand_prepares = 0;
						CHECK(invoke(aTHX_ entry, &req));
	#if defined(PERL_PRESERVE_IVUV) && !defined(PERL_RC_STACK)
						CHECK(!operand_prepares && "private IV/PVIV/PVNV arithmetic requires no general capture");
	#endif
						CHECK(req.result == expected && req.result_flags == expected_flags);
						CHECK(req.result_head == pad[1] && !PL_wump_task->critical);
						SvREFCNT_dec(target);
						SvREFCNT_dec(right);
						SvREFCNT_dec(left);
						checks++;
					}
				}
			}
		}
	}
	pad[1] = saved_target;
	CHECK(checks == 627);
}

static void numeric_exclusions(pTHX_ CV *entry, SV **pad) {
	SV *saved_target = pad[1];
	for (unsigned mode = 0; mode < 3; mode++) {
		SV *target = newSV_type(SVt_PVIV), *peer = NULL;
		sv_setpvs(target, "unchanged native string buffer retained by another scalar for the COW case");
		if (mode == 0) {
			/* Automatic copy heuristics can choose a deep copy. Shared hash
			 * keys provide native COW storage deterministically instead. */
			SvREFCNT_dec(target);
			target = newSVpvs_share("unchanged native string buffer retained by another scalar for the COW case");
			SvUPGRADE(target, SVt_PVIV);
			peer = newSVpvs_share("unchanged native string buffer retained by another scalar for the COW case");
			CHECK(SvIsCOW(target));
			CHECK(SvPVX_const(target) == SvPVX_const(peer));
		} else if (mode == 1) {
			sv_chop(target, SvPVX(target) + 1);
			CHECK(SvOOK(target));
		} else {
			sv_setuv(target, UV_MAX);
			CHECK(SvIsUV(target));
		}
		pad[1] = target;
		request req = {newSViv(42), newSViv(2), &operations[0], FALSE, 0};
		operand_prepares = 0;
		CHECK(invoke(aTHX_ entry, &req) && req.result == 44 && req.result_head == target);
		CHECK(operand_prepares && "COW, offset PV and UV targets must retain the general path");
		CHECK(!PL_wump_task->critical);
		if (peer) CHECK(strEQ(SvPV_nolen(peer),
			"unchanged native string buffer retained by another scalar for the COW case"));
		SvREFCNT_dec(req.source);
		SvREFCNT_dec(req.other);
		SvREFCNT_dec(peer);
		SvREFCNT_dec(target);
	}
	pad[1] = saved_target;
}

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
	SV *pad[2] = {NULL, newSV(0)};
	PL_curpad = pad;
	request req = {f->value, newSViv(2), &operations[0], FALSE, 0};
	int barrier = pthread_barrier_wait(&f->barrier);
	CHECK(barrier == 0 || barrier == PTHREAD_BARRIER_SERIAL_THREAD);
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
			switch (pass % 4) {
			case 0: sv_setiv(f->value, 42); break;
			case 1: sv_setuv(f->value, 42); break;
			case 2: sv_setnv(f->value, 42); break;
			default: sv_setpvs(f->value, "42"); break;
			}
			Perl_wump_mutation_end(aTHX_ guard);
		} else {
			req.op = &operations[pass % (sizeof(operations) / sizeof(operations[0]))];
			/* No caller-held read claim surrounds the opcode. Its public
			 * entry must protect even raw flag and body fast paths itself. */
			while (!invoke(aTHX_ f->entry, &req)) sched_yield();
			CHECK(req.result == req.op->expected);
		}
		FREETMPS;
		LEAVE;
	}
	SvREFCNT_dec(req.other);
	SvREFCNT_dec(pad[1]);
	SvREFCNT_dec(task.Ierrgv);
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
	char program[] = "opcode-operands", option[] = "-e", code[] = "0";
	char *embedding[] = {program, option, code, NULL};
	CHECK(perl_parse(interp, NULL, 3, embedding, NULL) == 0);
	dTHXa(interp);
	fixture f = {0};
	f.interp = aTHX;
	f.value = newSViv(42);
	publish_fast_leaf(aTHX_ f.value);
	f.entry = newXS("OperandFixture::invoke", execute_opcode, __FILE__);
	struct wump_perl_task writer = {0}, reader = {0};
	writer.interp = reader.interp = aTHX;
	writer.main = reader.main = 1;
	Perl_wump_task_activate(aTHX_ &writer);
	ENTER;
	SAVETMPS;
	struct wump_mutation *held = Perl_wump_mutation_begin(aTHX_ f.value);
	SV **original_pad = PL_curpad;
	SV *pad[2] = {NULL, newSV(0)};
	PL_curpad = pad;
	Perl_wump_task_activate(aTHX_ &reader);
	request req = {f.value, newSViv(2), &operations[0], argc == 2 && strEQ(argv[1], "--unguarded"), 0};
	bool rejected = !invoke(aTHX_ f.entry, &req);
	CHECK(rejected && "opcode must reject a foreign writer before reading cached fields");
	SvREFCNT_dec(req.other);
	Perl_wump_task_activate(aTHX_ &writer);
	Perl_wump_mutation_end(aTHX_ held);
	Perl_wump_task_activate(aTHX_ &reader);
	Perl_wump_memory_mark(aTHX_ f.value, 0);
	request publication = {f.value, f.value, &operations[1], FALSE, 0, TRUE};
	CHECK(invoke(aTHX_ f.entry, &publication) && publication.result == 0 && !publish_after_read);
	/* Cached integer operations on a private IV target need no allocating
	 * general operand capture. Keep the shared source and native entries. */
	sv_setiv(pad[1], 0);
	request numeric = {f.value, newSViv(2), &operations[0], FALSE, 0};
	for (unsigned i = 0; i < 2; i++) {
		numeric.op = &operations[i ? 4 : 0];
		operand_prepares = 0;
		CHECK(invoke(aTHX_ f.entry, &numeric) && numeric.result == numeric.op->expected);
#if defined(PERL_PRESERVE_IVUV) && !defined(PERL_RC_STACK)
		CHECK(!operand_prepares && "cached integer op must bypass general operand capture");
#else
		CHECK(operand_prepares && "alternate stacks retain general operand capture");
#endif
		CHECK(!PL_wump_task->critical);
	}
	/* A published target must retain its full mutation admission path. */
	Perl_wump_memory_mark(aTHX_ pad[1], 2);
	operand_prepares = 0;
	numeric.op = &operations[0];
	CHECK(invoke(aTHX_ f.entry, &numeric) && numeric.result == 44);
	CHECK(operand_prepares);
	Perl_wump_memory_mark(aTHX_ pad[1], 0);
	numeric_boundaries(aTHX_ f.entry, pad);
	numeric_exclusions(aTHX_ f.entry, pad);
	SvREFCNT_dec(numeric.other);
	SvREFCNT_dec(pad[1]);
	PL_curpad = original_pad;
	FREETMPS;
	LEAVE;
	Perl_wump_task_activate(aTHX_ NULL);
	CHECK(pthread_barrier_init(&f.barrier, NULL, workers) == 0);
	pthread_t threads[workers];
	argument args[workers];
	for (int id = 0; id < workers; id++) {
		Perl_wump_allocator_init(aTHX_ &f.pools[id]);
		args[id].f = &f;
		args[id].id = id;
		args[id].cop = PL_curcop;
		args[id].stash = PL_curstash;
		args[id].error = (GV *)newSV(0);
		gv_init(args[id].error, NULL, "__operand_error", 15, 0);
		CHECK(!GvSTASH(args[id].error) && !GvCVu(args[id].error));
		if (!GvSV(args[id].error)) GvSV(args[id].error) = newSVpvs("");
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
	puts("ok - scalar opcode entries reject active writers before raw cache reads");
	puts("ok - aliased inputs capture one value when publication completes between operand classifications");
	puts("ok - cached integer entries bypass general capture only with private numeric targets");
	puts("ok - 627 bounded numeric cases preserve native values, flags and result aliases in C/C++");
	puts("ok - COW, offset PV and UV targets retain native fallback behavior");
	puts("ok - six executors run 3072 actual arithmetic/comparison opcodes against 1024 concurrent representation changes");
	return 0;
}
