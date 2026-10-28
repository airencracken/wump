#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
enum { workers = 8, rounds = 512 };
typedef struct fixture {
	PerlInterpreter *interp;
	SV *value;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
} fixture;
typedef struct argument { fixture *f; int id; } argument;

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
	argument *ctx = arg;
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
			switch (pass % 4) {
			case 0: sv_setiv(f->value, 42); break;
			case 1: sv_setuv(f->value, 42); break;
			case 2: sv_setnv(f->value, 42); break;
			default: sv_setpvs(f->value, "42"); break;
			}
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
	fixture f = {0};
	f.interp = aTHX;
	f.value = newSViv(42);
	Perl_wump_publish(aTHX_ f.value);
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
	puts("ok - 6 readers and 2 writers contend on one scalar through 1024 representation changes and 3072 numeric/copy/encoding captures");
	return 0;
}
