#include "read-cases.h"
#include <pthread.h>

enum { workers = 8, rounds = 128 };
typedef struct reader {
	PerlInterpreter *interp;
	struct wump_perl_allocator pool;
	read_case *tests;
	pthread_barrier_t *barrier;
} reader;

static void *read_values(void *arg) {
	reader *ctx = (reader *)arg;
	dTHXa(ctx->interp);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ &ctx->pool);
	struct wump_perl_task task = {0};
	task.interp = aTHX;
	Perl_wump_task_activate(aTHX_ &task);
	JMPENV_BOOTSTRAP;
	init_stacks();
	task.initialized = 1;
	int result = pthread_barrier_wait(ctx->barrier);
	CHECK(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD);
	for (int pass = 0; pass < rounds; pass++) {
		ENTER;
		SAVETMPS;
		for (int i = 0; i < read_cases; i++) exercise_case(aTHX_ &ctx->tests[i]);
		FREETMPS;
		LEAVE;
	}
	CHECK(task.read_frame == NULL);
	while (PL_curstackinfo) {
		PERL_SI *si = PL_curstackinfo;
		PERL_SI *previous = si->si_prev;
		SvREFCNT_dec(si->si_stack);
		Safefree(si->si_cxstack);
		Safefree(si);
		PL_curstackinfo = previous;
	}
	Safefree(PL_tmps_stack);
	Safefree(PL_markstack);
	Safefree(PL_scopestack);
#ifdef DEBUGGING
	Safefree(PL_scopestack_name);
#endif
	Safefree(PL_savestack);
	CHECK(ctx->pool.Isv_count == 0);
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
	read_case tests[read_cases];
	SV *alias;
	build_cases(aTHX_ tests, &alias);
	reader contexts[workers];
	pthread_t threads[workers];
	pthread_barrier_t barrier;
	CHECK(pthread_barrier_init(&barrier, NULL, workers) == 0);
	for (int i = 0; i < workers; i++) {
		contexts[i].interp = aTHX;
		contexts[i].tests = tests;
		contexts[i].barrier = &barrier;
		Perl_wump_allocator_init(aTHX_ &contexts[i].pool);
		CHECK(pthread_create(&threads[i], NULL, read_values, &contexts[i]) == 0);
	}
	for (int i = 0; i < workers; i++) {
		CHECK(pthread_join(threads[i], NULL) == 0);
		Perl_wump_allocator_merge(aTHX_ &contexts[i].pool);
	}
	CHECK(pthread_barrier_destroy(&barrier) == 0);
	for (int i = 0; i < read_cases; i++) {
		unchanged_case(aTHX_ &tests[i]);
		SvREFCNT_dec(tests[i].value);
	}
	SvREFCNT_dec(alias);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - 8 concurrent readers complete 14336 shared scalar read/copy cycles without source mutation or leaked snapshots");
	return 0;
}
