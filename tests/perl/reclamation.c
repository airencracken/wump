#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

/* Force the core's COW path independently of its small-string heuristics. */
extern SV *Perl_sv_setsv_cow(pTHX_ SV *, SV *);

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

enum { workers = 8, rounds = 128 };
typedef struct fixture {
	PerlInterpreter *interp;
	pthread_barrier_t barrier;
	struct wump_perl_allocator pools[workers];
	AV *root, *array;
	HV *hash;
	SV *scalar, *aliases[rounds][workers];
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
	rendezvous(f);
	/* All publishers race on the same graph; returning must mean the entire
	 * graph is shared, including another publisher's in-progress descendants. */
	ENTER;
	Perl_wump_publish(aTHX_ (SV *)f->root);
	CHECK(Perl_wump_is_shared(aTHX_ f->scalar));
	CHECK(Perl_wump_is_shared(aTHX_ (SV *)f->array));
	CHECK(Perl_wump_is_shared(aTHX_ (SV *)f->hash));
	LEAVE;
	rendezvous(f);
	for (int pass = 0; pass < rounds; pass++) {
		ENTER;
		SAVETMPS;
		char expected[80];
		snprintf(expected, sizeof(expected), "generation-%d: cached storage surviving executor replacement", pass);
		STRLEN length = 0;
		const char *bytes = NULL;
		SV **slot = NULL;
		HE *entry = NULL;
		if (ctx->id) {
			bytes = SvPV_const(f->scalar, length);
			slot = Perl_wump_borrow_av(aTHX_ f->array, 0);
			entry = Perl_wump_borrow_hv(aTHX_ f->hash, "key", 3, 0);
			CHECK(slot && entry);
		}
		SV *alias = f->aliases[pass][ctx->id];
		Perl_wump_publish(aTHX_ alias);
		const char *cow = NULL;
		STRLEN cow_length = 0;
		if (!ctx->id) cow = SvPV_const(alias, cow_length);
		rendezvous(f);
		/* Distinct COW heads share one byte-counted buffer. Their concurrent
		 * split/free paths must retain that buffer through the final copy. */
		sv_catpvs(alias, " changed");
		if (!ctx->id) {
			char next[80];
			snprintf(next, sizeof(next), "generation-%d: cached storage surviving executor replacement", pass + 1);
			sv_setpv(f->scalar, next);
			CHECK(av_store(f->array, 0, newSVpv(next, 0)));
			av_extend(f->array, 64 + pass);
			(void)hv_delete(f->hash, "key", 3, G_DISCARD);
			CHECK(hv_store(f->hash, "key", 3, newSVpv(next, 0), 0));
			hv_ksplit(f->hash, 64 + pass);
		}
		rendezvous(f);
		if (ctx->id) {
			CHECK(length == strlen(expected) && memEQ(bytes, expected, length));
			CHECK(strEQ(SvPV_nolen(*slot), expected));
			CHECK(strEQ(SvPV_nolen(HeVAL(entry)), expected));
		} else {
			CHECK(cow_length == 96);
			for (STRLEN i = 0; i < cow_length; i++) CHECK(cow[i] == 'x');
		}
		FREETMPS;
		LEAVE;
		rendezvous(f);
		if (!ctx->id) {
			size_t pins, pending, nodes;
			Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
			CHECK(!pins && !pending);
		}
		rendezvous(f);
	}
	drop_stacks(aTHX);
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

typedef struct migration {
	PerlInterpreter *interp;
	struct wump_perl_allocator pools[2];
	struct wump_perl_task task;
	SV *value;
	const char *bytes;
	STRLEN length;
} migration;

static void *capture(void *arg) {
	migration *m = arg;
	dTHXa(m->interp);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ &m->pools[0]);
	Perl_wump_task_activate(aTHX_ &m->task);
	JMPENV_BOOTSTRAP;
	init_stacks();
	m->task.initialized = 1;
	ENTER;
	SAVETMPS;
	m->bytes = SvPV_const(m->value, m->length);
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	return NULL;
}

static void *release_migrated(void *arg) {
	migration *m = arg;
	dTHXa(m->interp);
	PERL_SET_CONTEXT(aTHX);
	Perl_wump_allocator_activate(aTHX_ &m->pools[1]);
	Perl_wump_task_activate(aTHX_ &m->task);
	JMPENV_BOOTSTRAP;
	CHECK(m->length == 16 && memEQ(m->bytes, "migrating buffer", 16));
	FREETMPS;
	LEAVE;
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
	f.interp = interp;
	f.root = newAV();
	f.array = newAV();
	f.hash = newHV();
	f.scalar = newSVpvs("generation-0: cached storage surviving executor replacement");
	av_push(f.root, SvREFCNT_inc(f.scalar));
	av_push(f.root, newRV_noinc((SV *)f.array));
	av_push(f.root, newRV_noinc((SV *)f.hash));
	av_push(f.array, newSVsv(f.scalar));
	CHECK(hv_store(f.hash, "key", 3, newSVsv(f.scalar), 0));
	char text[97];
	memset(text, 'x', 96);
	text[96] = '\0';
	for (int pass = 0; pass < rounds; pass++) {
		f.aliases[pass][0] = newSVpvn(text, 96);
		(void)SvGROW(f.aliases[pass][0], 100);
		for (int id = 1; id < workers; id++) {
			f.aliases[pass][id] = Perl_sv_setsv_cow(aTHX_ NULL, f.aliases[pass][0]);
			CHECK(SvPVX_const(f.aliases[pass][id]) == SvPVX_const(f.aliases[pass][0]));
		}
	}
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
	for (int pass = 0; pass < rounds; pass++)
		for (int id = 0; id < workers; id++) SvREFCNT_dec(f.aliases[pass][id]);
	SvREFCNT_dec(f.root);
	SvREFCNT_dec(f.scalar);
	migration m = {0};
	m.interp = aTHX;
	m.task.interp = aTHX;
	m.value = newSVpvs("migrating buffer");
	Perl_wump_publish(aTHX_ m.value);
	for (int id = 0; id < 2; id++) Perl_wump_allocator_init(aTHX_ &m.pools[id]);
	pthread_t migrant;
	CHECK(pthread_create(&migrant, NULL, capture, &m) == 0);
	CHECK(pthread_join(migrant, NULL) == 0);
	struct wump_perl_task main_task = {0};
	main_task.interp = aTHX;
	main_task.main = 1;
	Perl_wump_task_activate(aTHX_ &main_task);
	sv_setpvs(m.value, "replacement");
	Perl_wump_task_activate(aTHX_ NULL);
	CHECK(pthread_create(&migrant, NULL, release_migrated, &m) == 0);
	CHECK(pthread_join(migrant, NULL) == 0);
	for (int id = 0; id < 2; id++) Perl_wump_allocator_merge(aTHX_ &m.pools[id]);
	SvREFCNT_dec(m.value);
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - 8 executors publish one graph, preserve 2688 borrowed buffers/slots/entries across writes, split 1024 COW aliases, and reclaim at quiescence");
	puts("ok - a parked task carries its borrowed buffer to another executor and releases it there");
	return 0;
}
