#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(MYMALLOC) || defined(PERL_TRACK_MEMPOOL) || defined(DEBUG_LEAKING_SCALARS)
#error "Executor fixture requires system malloc without Perl memory tracking"
#endif

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

enum { workers = 8, batch = 512, rounds = 32 };
typedef struct fixture {
	PerlInterpreter *interp, *other;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
	SV *values[workers][batch], *survivors[workers], *roots[workers];
} fixture;
typedef struct thread_arg { fixture *f; int id; } thread_arg;

static void rendezvous(fixture *f) {
	int result = pthread_barrier_wait(&f->barrier);
	CHECK(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD);
}

static SV *make_value(pTHX_ int value) {
	switch (value % 4) {
	case 0: return newSViv(value);
	case 1: return newSVnv(value + 0.25);
	case 2: {
		SV *sv = newSVpvs("executor");
		sv_catpvs(sv, "-private string buffer that grows");
		return sv;
	}
	default: {
		AV *av = newAV();
		for (int i = 0; i < 4; i++) av_push(av, newSViv(value + i));
		return newRV_noinc((SV *)av);
	}
	}
}

static void check_value(pTHX_ SV *sv, int value) {
	switch (value % 4) {
	case 0: CHECK(SvIV(sv) == value); break;
	case 1: CHECK(SvNV(sv) == value + 0.25); break;
	case 2: CHECK(strEQ(SvPV_nolen(sv), "executor-private string buffer that grows")); break;
	default: {
		CHECK(SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV);
		AV *av = (AV *)SvRV(sv);
		CHECK(AvFILL(av) == 3);
		for (int i = 0; i < 4; i++) CHECK(SvIV(*av_fetch(av, i, 0)) == value + i);
	}
	}
}

static void drop_stacks(pTHX) {
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
}

static void *exercise(void *arg) {
	thread_arg *ctx = arg;
	fixture *f = ctx->f;
	dTHXa(f->interp);
	PERL_SET_CONTEXT(aTHX);
	struct wump_perl_allocator *pool = &f->pools[ctx->id];
	Perl_wump_allocator_activate(aTHX_ pool);
	CHECK(Perl_wump_allocator_current(aTHX) == pool);
	CHECK(&PL_sv_root == &pool->Isv_root && &PL_body_roots == &pool->Ibody_roots);
	/* The receiving executor accounts for frees, even for root allocations. */
	SvREFCNT_dec(f->roots[ctx->id]);
	CHECK(PL_sv_count == -1);
	struct wump_perl_task task = { .interp = aTHX };
	Perl_wump_task_activate(aTHX_ &task);
	JMPENV_BOOTSTRAP;
	init_stacks();
	task.initialized = 1;
	PERL_SET_CONTEXT(f->other);
	{
		dTHX;
		CHECK(Perl_wump_allocator_current(aTHX) == NULL);
		CHECK(&PL_sv_root == &f->other->Isv_root);
	}
	PERL_SET_CONTEXT(f->interp);
	for (int round = 0; round < rounds; round++) {
		for (int i = 0; i < batch; i++) f->values[ctx->id][i] = make_value(aTHX_ round * batch + i);
		rendezvous(f);
		rendezvous(f); /* Main validates live values before any final drop. */
		int source = (ctx->id + 1) % workers;
		for (int i = 0; i < batch; i++) SvREFCNT_dec(f->values[source][i]);
		rendezvous(f); /* No producer may overwrite a row still being freed. */
	}
	if (ctx->id) f->survivors[ctx->id] = newSViv(ctx->id);
	drop_stacks(aTHX);
	CHECK(PL_sv_count == (ctx->id ? 0 : -1));
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

static int compare_pointers(const void *a, const void *b) {
	uintptr_t x = (uintptr_t)*(SV *const *)a, y = (uintptr_t)*(SV *const *)b;
	return (x > y) - (x < y);
}

static void *race_allocator(void *arg) {
	fixture *f = arg;
	dTHXa(f->interp);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ &f->pools[0]);
	rendezvous(f);
	/* Negative control: two threads deliberately misuse one executor's
	 * cache. The conflicting writes happen inside Perl's C allocator. */
	for (int i = 0; i < 64; i++) Perl_more_bodies(aTHX_ SVt_PVNV, sizeof(XPVNV), PERL_ARENA_SIZE);
	return NULL;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	fixture f = {0};
	f.interp = perl_alloc();
	f.other = perl_alloc();
	CHECK(f.interp && f.other);
	PERL_SET_CONTEXT(f.other);
	perl_construct(f.other);
	PERL_SET_CONTEXT(f.interp);
	perl_construct(f.interp);
	dTHXa(f.interp);
	if (argc == 2 && strEQ(argv[1], "--race")) {
		f.pools[0].interp = aTHX;
		CHECK(pthread_barrier_init(&f.barrier, NULL, 2) == 0);
		pthread_t racers[2];
		for (int i = 0; i < 2; i++) CHECK(pthread_create(&racers[i], NULL, race_allocator, &f) == 0);
		for (int i = 0; i < 2; i++) CHECK(pthread_join(racers[i], NULL) == 0);
		fputs("FAIL: expected TSan to stop the shared-cache race\n", stderr);
		return 1;
	}
	CHECK(argc == 1);
	IV baseline = PL_sv_count;
	for (int i = 0; i < workers; i++) {
		f.pools[i].interp = aTHX;
		f.roots[i] = newSViv(i);
	}
	SV *root = PL_sv_root, *arenas = PL_sv_arenaroot;
	void *bodies = PL_body_arenas;
	void *body_roots[PERL_ARENA_ROOTS_SIZE];
	Copy(PL_body_roots, body_roots, PERL_ARENA_ROOTS_SIZE, void *);
	CHECK(pthread_barrier_init(&f.barrier, NULL, workers + 1) == 0);
	pthread_t threads[workers];
	thread_arg args[workers];
	for (int i = 0; i < workers; i++) {
		args[i] = (thread_arg){&f, i};
		CHECK(pthread_create(&threads[i], NULL, exercise, &args[i]) == 0);
	}
	for (int round = 0; round < rounds; round++) {
		rendezvous(&f);
		CHECK(Perl_wump_allocator_current(aTHX) == NULL);
		CHECK(PL_sv_root == root && PL_sv_arenaroot == arenas && PL_body_arenas == bodies);
		CHECK(PL_sv_count == baseline + workers);
		CHECK(memEQ(PL_body_roots, body_roots, sizeof(body_roots)));
		SV *live[workers * batch];
		for (int n = 0; n < workers; n++) {
			for (int i = 0; i < batch; i++) {
				check_value(aTHX_ f.values[n][i], round * batch + i);
				live[n * batch + i] = f.values[n][i];
			}
		}
		qsort(live, workers * batch, sizeof(*live), compare_pointers);
		for (int i = 1; i < workers * batch; i++) CHECK(live[i - 1] != live[i]);
		rendezvous(&f);
		rendezvous(&f);
	}
	for (int i = 0; i < workers; i++) CHECK(pthread_join(threads[i], NULL) == 0);
	CHECK(pthread_barrier_destroy(&f.barrier) == 0);
	/* A quiescent executor cache can move to another native thread. */
	Perl_wump_allocator_activate(aTHX_ &f.pools[0]);
	SV *moved = newSViv(42);
	Perl_wump_allocator_activate(aTHX_ NULL);
	for (int i = 0; i < workers; i++) {
		Perl_wump_allocator_merge(aTHX_ &f.pools[i]);
		Perl_wump_allocator_merge(aTHX_ &f.pools[i]);
		CHECK(f.pools[i].Isv_count == 0 && f.pools[i].Isv_root == NULL
			&& f.pools[i].Isv_arenaroot == NULL && f.pools[i].Ibody_arenas == NULL);
	}
	CHECK(PL_sv_count == baseline + workers);
	CHECK(SvIV(moved) == 42);
	SvREFCNT_dec(moved);
	for (int i = 1; i < workers; i++) {
		CHECK(SvIV(f.survivors[i]) == i);
		SvREFCNT_dec(f.survivors[i]);
	}
	CHECK(PL_sv_count == baseline);
	/* Reuse merged heads and bodies before global arena teardown. */
	for (int i = 0; i < batch; i++) {
		SV *sv = make_value(aTHX_ i);
		check_value(aTHX_ sv, i);
		SvREFCNT_dec(sv);
	}
	CHECK(PL_sv_count == baseline);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(f.interp) == 0);
	perl_free(f.interp);
	PERL_SET_CONTEXT(f.other);
	f.other->Iperl_destruct_level = 2;
	CHECK(perl_destruct(f.other) == 0);
	perl_free(f.other);
	PERL_SYS_TERM();
	puts("ok - 8 executors isolate allocation, exchange 131072 values, migrate caches, and merge surviving values for full teardown");
	return 0;
}
