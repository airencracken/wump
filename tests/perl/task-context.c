#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

enum { iterations = 100000 };
typedef struct fixture {
	PerlInterpreter *interp, *other;
	pthread_barrier_t barrier;
	atomic_int failed;
	OP *root, *other_root;
} fixture;
typedef struct thread_arg { fixture *f; int id; } thread_arg;

static void activate(pTHX_ struct wump_perl_task *task) {
#ifdef WUMP_TASK_LEGACY
	/* Adapter for exercising the pre-TLS revision with this same fixture. */
	aTHX->Iwump_task = task;
#else
	Perl_wump_task_activate(aTHX_ task);
#endif
}

static void rendezvous(fixture *f) {
	int result = pthread_barrier_wait(&f->barrier);
	if (result != 0 && result != PTHREAD_BARRIER_SERIAL_THREAD) abort();
}

static void *exercise(void *arg) {
	thread_arg *ctx = arg;
	fixture *f = ctx->f;
	dTHXa(f->interp);
	PERL_SET_CONTEXT(aTHX);
	OP ops[2] = {{0}, {0}};
	SV *stack[2] = {NULL, NULL};
	struct wump_perl_task task = {.interp = aTHX, .Iop = &ops[0], .Istack_sp = stack};
	if (PL_wump_task != NULL) atomic_store(&f->failed, 1);
	rendezvous(f);
	/* Order activations so the old shared-slot failure is deterministic,
	 * without introducing a deliberate unsynchronized pointer-write race. */
	if (ctx->id == 0) activate(aTHX_ &task);
	rendezvous(f);
	if (ctx->id == 1) activate(aTHX_ &task);
	rendezvous(f);
	for (int i = 0; i < iterations; i++) {
		if (PL_wump_task != &task) { atomic_store(&f->failed, 1); continue; }
		PL_op = &ops[i % 2];
		PL_stack_sp = &stack[i % 2];
		PL_savestack_ix = i;
		if (!(i % 100)) sched_yield();
		if (PL_wump_task != &task || PL_op != &ops[i % 2]
			|| PL_stack_sp != &stack[i % 2] || PL_savestack_ix != i)
			atomic_store(&f->failed, 1);
		PERL_SET_CONTEXT(f->other);
		{
			dTHX;
			if (PL_wump_task != NULL || PL_op != f->other_root)
				atomic_store(&f->failed, 1);
		}
		PERL_SET_CONTEXT(f->interp);
	}
	rendezvous(f);
	if (ctx->id == 0) activate(aTHX_ NULL);
	rendezvous(f);
	if (ctx->id == 1 && PL_wump_task != &task) atomic_store(&f->failed, 1);
	rendezvous(f);
	if (ctx->id == 1) activate(aTHX_ NULL);
	return NULL;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	fixture f = {0};
	atomic_init(&f.failed, 0);
	f.interp = perl_alloc();
	f.other = perl_alloc();
	if (!f.interp || !f.other) return 1;
	PERL_SET_CONTEXT(f.other);
	perl_construct(f.other);
	PERL_SET_CONTEXT(f.interp);
	perl_construct(f.interp);
	dTHXa(f.interp);
	f.root = PL_op;
	f.other_root = f.other->Iop;
	if (pthread_barrier_init(&f.barrier, NULL, 3)) return 1;
	pthread_t threads[2];
	thread_arg args[2] = {{&f, 0}, {&f, 1}};
	for (int i = 0; i < 2; i++) if (pthread_create(&threads[i], NULL, exercise, &args[i])) abort();
	rendezvous(&f);
	rendezvous(&f);
	rendezvous(&f);
	if (PL_wump_task != NULL || PL_op != f.root) atomic_store(&f.failed, 1);
	rendezvous(&f);
	rendezvous(&f);
	if (PL_wump_task != NULL || PL_op != f.root) atomic_store(&f.failed, 1);
	rendezvous(&f);
	for (int i = 0; i < 2; i++) if (pthread_join(threads[i], NULL)) abort();
	pthread_barrier_destroy(&f.barrier);
	activate(aTHX_ NULL);
	PERL_SET_CONTEXT(f.other);
	perl_destruct(f.other);
	perl_free(f.other);
	PERL_SET_CONTEXT(f.interp);
	perl_destruct(f.interp);
	perl_free(f.interp);
	PERL_SYS_TERM();
	if (atomic_load(&f.failed)) {
		fprintf(stderr, "FAIL: native threads observed another task or changed root interpreter state\n");
		return 1;
	}
	puts("ok - two native threads isolate task state and preserve both interpreters' root state through 200,000 iterations");
	return 0;
}
