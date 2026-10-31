#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
static _Thread_local unsigned locks;
static _Thread_local bool fail_registration, writer_thread;
static _Atomic unsigned writer_locked;
extern int __real_pthread_mutex_lock(pthread_mutex_t *);
int __wrap_pthread_mutex_lock(pthread_mutex_t *mutex) {
	locks++;
	int result = __real_pthread_mutex_lock(mutex);
	if (writer_thread && !result) atomic_store(&writer_locked, 1);
	return result;
}
extern int __real_posix_memalign(void **, size_t, size_t);
int __wrap_posix_memalign(void **output, size_t alignment, size_t bytes) {
	if (fail_registration) { fail_registration = FALSE; return ENOMEM; }
	return __real_posix_memalign(output, alignment, bytes);
}

static void root_paths(pTHX_ PerlInterpreter *other) {
	struct wump_perl_task task = {0};
	task.interp = aTHX; task.main = 1;
	Perl_wump_task_activate(aTHX_ &task);
	struct wump_perl_allocator pool;
	Perl_wump_allocator_init(aTHX_ &pool);
	Perl_wump_allocator_activate(aTHX_ &pool);
	OP op = {0}; op.op_type = OP_ADD;
	OP *saved_op = PL_op;
	SV **saved_sp = PL_stack_sp;
	SV *stack[2] = {newSViv(40), newSViv(2)}, *target = newSViv(0);
	PL_op = &op; PL_stack_sp = stack + 1;
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	locks = 0;
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	unsigned fast_locks = locks;
	CHECK(!task.critical);
	CHECK(!fast_locks && "warmed numeric admission must not take the metadata mutex");
	/* Returning to metadata work makes this executor's slot dormant.
	 * Rearming must reuse its allocation, including under memory pressure. */
	for (unsigned repeat = 0; repeat < 32; repeat++) {
		if (repeat & 1) {
			size_t pins, retired, nodes;
			Perl_wump_memory_stats(aTHX_ &pins, &retired, &nodes);
		} else {
			Perl_wump_memory_lock(aTHX); Perl_wump_memory_unlock(aTHX);
		}
		fail_registration = TRUE;
		locks = 0;
		CHECK(Perl_wump_numeric_enter(aTHX_ target));
		Perl_wump_numeric_leave(aTHX);
		CHECK((repeat & 1) || locks);
		locks = 0;
		CHECK(Perl_wump_numeric_enter(aTHX_ target));
		Perl_wump_numeric_leave(aTHX);
		CHECK((repeat & 1) || (locks && "isolated arithmetic must retain cold mutex admission"));
		CHECK(fail_registration && !task.critical);
		fail_registration = FALSE;
		locks = 0;
		CHECK(Perl_wump_numeric_enter(aTHX_ target));
		Perl_wump_numeric_leave(aTHX);
		CHECK(!locks && "rearmed numeric admission must retain its mutex-free path");
	}
	/* A published target must be rejected from registry state before any
	 * head access: a foreign logical writer may be changing that head.
	 * An inaccessible sentinel makes an early flag read deterministic. */
	long page_size = sysconf(_SC_PAGESIZE);
	CHECK(page_size > 0);
	SV *sentinel = mmap(NULL, (size_t)page_size, PROT_NONE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(sentinel != MAP_FAILED);
	Perl_wump_memory_mark(aTHX_ sentinel, 2);
	CHECK(!Perl_wump_numeric_enter(aTHX_ sentinel));
	Perl_wump_memory_forget(aTHX_ sentinel);
	CHECK(munmap(sentinel, (size_t)page_size) == 0);
	/* A failed eligibility test must withdraw its announcement. */
	sv_setiv(stack[1], 0);
	op.op_type = OP_MODULO;
	CHECK(!Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_memory_lock(aTHX); Perl_wump_memory_unlock(aTHX);
	op.op_type = OP_ADD; sv_setiv(stack[1], 2);
	/* Native recursive regions use the existing recursive admission. */
	Perl_wump_memory_lock(aTHX);
	locks = 0;
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	CHECK(locks && !task.critical);
	/* Metadata depth must survive nested interpreters and non-LIFO
	 * release, without retaining a native TLS address across a callback. */
	PERL_SET_CONTEXT(other);
	Perl_wump_memory_lock(other);
	PERL_SET_CONTEXT(aTHX);
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	Perl_wump_memory_unlock(aTHX);
	PERL_SET_CONTEXT(other);
	Perl_wump_memory_unlock(other);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ NULL);
	Perl_wump_allocator_merge(aTHX_ &pool);
	/* Registration OOM is a performance fallback, not a new Perl error. */
	Perl_wump_allocator_init(aTHX_ &pool);
	Perl_wump_allocator_activate(aTHX_ &pool);
	fail_registration = TRUE;
	locks = 0;
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	CHECK(!fail_registration && locks && !task.critical);
	CHECK(Perl_wump_numeric_enter(aTHX_ target));
	Perl_wump_numeric_leave(aTHX);
	/* Teardown also handles an allocated but dormant slot. */
	Perl_wump_memory_lock(aTHX); Perl_wump_memory_unlock(aTHX);
	Perl_wump_allocator_activate(aTHX_ NULL);
	Perl_wump_allocator_merge(aTHX_ &pool);
	Perl_wump_allocator_merge(aTHX_ &pool);
	PL_stack_sp = saved_sp; PL_op = saved_op;
	SvREFCNT_dec(target); SvREFCNT_dec(stack[1]); SvREFCNT_dec(stack[0]);
	Perl_wump_task_activate(aTHX_ NULL);
}

typedef struct fixture {
	PerlInterpreter *interp;
	SV *source;
	COP *cop;
	HV *stash;
	GV *default_gv;
	_Atomic unsigned ready[2], start[2], entered[2], release[2], writer_done;
	_Atomic unsigned gate_ready, gate_release, writer_go, mutex_calls[2];
	_Atomic unsigned query_ready, query_go, query_done, query_release;
	struct wump_perl_allocator pools[4];
	bool unguarded;
} fixture;
typedef struct argument { fixture *f; int id; } argument;

static bool wait_flag(_Atomic unsigned *flag, unsigned milliseconds) {
	struct timespec now;
	CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
	double end = now.tv_sec + now.tv_nsec / 1e9 + milliseconds / 1000.0;
	while (!atomic_load(flag)) {
		CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
		if (now.tv_sec + now.tv_nsec / 1e9 >= end) return FALSE;
		sched_yield();
	}
	return TRUE;
}

static void drop_stacks(pTHX) {
	while (PL_curstackinfo->si_next) PL_curstackinfo = PL_curstackinfo->si_next;
	while (PL_curstackinfo) {
		PERL_SI *si = PL_curstackinfo;
		PL_curstackinfo = si->si_prev;
		SvREFCNT_dec(si->si_stack); Safefree(si->si_cxstack); Safefree(si);
	}
	Safefree(PL_tmps_stack); Safefree(PL_markstack); Safefree(PL_scopestack);
#ifdef DEBUGGING
	Safefree(PL_scopestack_name);
#endif
	Safefree(PL_savestack);
}

static void *exercise(void *arg) {
	argument *ctx = arg;
	fixture *f = ctx->f;
	dTHXa(f->interp);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ &f->pools[ctx->id]);
	struct wump_perl_task task = {0};
	task.interp = aTHX; task.Icurcop = f->cop; task.Icurstash = f->stash;
	Perl_wump_task_activate(aTHX_ &task);
	JMPENV_BOOTSTRAP;
	init_stacks(); task.initialized = 1;
	ENTER; SAVETMPS;
	if (ctx->id == 3) {
		SV *private_value = newSViv(17);
		HV *private_hash = newHV();
		SV *completed_value = newSViv(73);
		Perl_wump_publish(aTHX_ completed_value);
		struct wump_mutation *completed = Perl_wump_mutation_begin(aTHX_ completed_value);
		CHECK(completed);
		sv_setiv(completed_value, 74);
		atomic_store(&f->query_ready, 1);
		while (!atomic_load(&f->query_go)) sched_yield();
		Perl_wump_mutation_end(aTHX_ completed);
		CHECK(Perl_wump_memory_shared(aTHX_ f->source) == 1);
		Perl_wump_memory_check(aTHX_ f->source);
		CHECK(Perl_wump_is_shared(aTHX_ f->source));
		CHECK(!Perl_wump_is_shared(aTHX_ private_value));
		CHECK(!Perl_wump_is_shared(aTHX_ (SV *)private_hash));
		CHECK(Perl_wump_is_shared(aTHX_ (SV *)f->stash));
		CHECK(Perl_wump_is_shared(aTHX_ (SV *)f->default_gv));
		struct wump_shared *claim = Perl_wump_read_begin(aTHX_ f->source);
		CHECK(claim);
		Perl_wump_read_end(aTHX_ claim);
		struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ f->source);
		CHECK(capture);
		size_t pins, retired, nodes;
		Perl_wump_memory_stats(aTHX_ &pins, &retired, &nodes);
		CHECK(pins && nodes);
		Perl_wump_capture_end(aTHX_ capture);
		Perl_wump_memory_collect(aTHX);
		Perl_wump_publish(aTHX_ f->source);
		atomic_store(&f->query_done, 1);
		while (!atomic_load(&f->query_release)) sched_yield();
		SvREFCNT_dec(private_value);
		SvREFCNT_dec(private_hash);
		SvREFCNT_dec(completed_value);
	} else if (ctx->id == 2) {
		Perl_wump_memory_lock(aTHX);
		atomic_store(&f->gate_ready, 1);
		while (!atomic_load(&f->gate_release)) sched_yield();
		Perl_wump_memory_unlock(aTHX);
		while (!atomic_load(&f->writer_go)) sched_yield();
		writer_thread = TRUE;
		bool busy;
		struct wump_mutation *guard;
		do {
			guard = Perl_wump_mutation_try_begin(aTHX_ f->source, &busy);
			if (busy) sched_yield();
		} while (busy);
		CHECK(guard);
		sv_setiv(f->source, 99);
		Perl_wump_mutation_end(aTHX_ guard);
		atomic_store(&f->writer_done, 1);
		writer_thread = FALSE;
	} else {
		OP op = {0}; op.op_type = OP_ADD;
		PL_op = &op;
		SV *target = newSViv(0), *rhs = newSViv(2);
		SV **saved_sp = PL_stack_sp;
		SV *stack[2] = {f->source, rhs}; PL_stack_sp = stack + 1;
		CHECK(Perl_wump_numeric_enter(aTHX_ target));
		Perl_wump_numeric_leave(aTHX);
		CHECK(Perl_wump_numeric_enter(aTHX_ target));
		Perl_wump_numeric_leave(aTHX);
		atomic_store(&f->ready[ctx->id], 1);
		while (!atomic_load(&f->start[ctx->id])) sched_yield();
		bool guarded = !f->unguarded || ctx->id == 0;
		locks = 0;
		if (guarded) CHECK(Perl_wump_numeric_enter(aTHX_ target));
		/* Reader one protects the negative control's initial read. After
		 * this point that control uses only atomics, avoiding a racy test. */
		CHECK(SvIVX(f->source) == 42);
		atomic_store(&f->entered[ctx->id], 1);
		while (!atomic_load(&f->release[ctx->id])) sched_yield();
		if (guarded) Perl_wump_numeric_leave(aTHX);
		atomic_store(&f->mutex_calls[ctx->id], locks);
		CHECK(!task.critical);
		PL_stack_sp = saved_sp; PL_op = NULL;
		SvREFCNT_dec(rhs); SvREFCNT_dec(target);
	}
	FREETMPS; LEAVE;
	drop_stacks(aTHX);
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc(), *other = perl_alloc();
	CHECK(interp && other);
	PERL_SET_CONTEXT(other); perl_construct(other);
	PERL_SET_CONTEXT(interp); perl_construct(interp);
	char program[] = "numeric-admission", option[] = "-e", code[] = "0";
	char *embedding[] = {program, option, code, NULL};
	CHECK(perl_parse(interp, NULL, 3, embedding, NULL) == 0);
	dTHXa(interp);
	root_paths(aTHX_ other);
	fixture f = {0};
	f.interp = aTHX; f.cop = PL_curcop; f.stash = PL_curstash;
	f.default_gv = PL_defgv;
	f.unguarded = argc == 2 && strEQ(argv[1], "--unguarded-reader");
	f.source = newSViv(42);
	Perl_wump_publish(aTHX_ f.source);
	for (int id = 0; id < 4; id++) Perl_wump_allocator_init(aTHX_ &f.pools[id]);
	pthread_t threads[4]; argument args[4] = {{&f, 0}, {&f, 1}, {&f, 2}, {&f, 3}};
	CHECK(pthread_create(&threads[0], NULL, exercise, &args[0]) == 0);
	CHECK(pthread_create(&threads[1], NULL, exercise, &args[1]) == 0);
	CHECK(pthread_create(&threads[3], NULL, exercise, &args[3]) == 0);
	CHECK(wait_flag(&f.ready[0], 3000) && wait_flag(&f.ready[1], 3000));
	CHECK(wait_flag(&f.query_ready, 3000));
	CHECK(pthread_create(&threads[2], NULL, exercise, &args[2]) == 0);
	CHECK(wait_flag(&f.gate_ready, 3000));
	atomic_store(&f.start[0], 1);
	bool passed_gate = wait_flag(&f.entered[0], 50);
	atomic_store(&f.gate_release, 1);
	CHECK(wait_flag(&f.entered[0], 3000));
	atomic_store(&f.start[1], 1);
	bool overlap = wait_flag(&f.entered[1], 3000);
	atomic_store(&f.query_go, 1);
	bool queried = wait_flag(&f.query_done, 1000);
	atomic_store(&f.writer_go, 1);
	bool writer_started = wait_flag(&writer_locked, 3000);
	bool premature = atomic_load(&f.writer_done) != 0;
	atomic_store(&f.release[0], 1);
	premature |= wait_flag(&f.writer_done, 250);
	atomic_store(&f.release[1], 1);
	atomic_store(&f.query_release, 1);
	for (int id = 0; id < 4; id++) CHECK(pthread_join(threads[id], NULL) == 0);
	for (int id = 0; id < 4; id++) Perl_wump_allocator_merge(aTHX_ &f.pools[id]);
	CHECK(!atomic_load(&f.mutex_calls[0]) && !atomic_load(&f.mutex_calls[1])
		&& "busy numeric admission must not convoy on the metadata mutex");
	CHECK(!passed_gate && "new numeric reader passed a closed writer gate");
	CHECK(queried && "registry-only queries must run beside admitted numeric readers");
	CHECK(overlap && "independent numeric readers must be admitted concurrently");
	CHECK(writer_started && "writer must acquire metadata mutex while numeric readers run");
	CHECK(!premature && "metadata writer passed an admitted numeric reader");
	CHECK(atomic_load(&f.writer_done) && SvIV(f.source) == 99);
	SvREFCNT_dec(f.source);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0); perl_free(interp);
	PERL_SET_CONTEXT(other); CHECK(perl_destruct(other) == 0); perl_free(other);
	PERL_SYS_TERM();
	puts("ok - warmed numeric admission takes no mutex and withdraws failed eligibility");
	puts("ok - recursive/nested interpreter regions and registration OOM retain safe fallback");
	puts("ok - dormant slots rearm without allocation and merge safely");
	puts("ok - independent numeric readers overlap and exclude metadata writers until both leave");
	puts("ok - a closed writer gate defers new readers without queuing them on its mutex");
	puts("ok - registry-only queries and read claims coexist with admitted numeric readers");
	return 0;
}
