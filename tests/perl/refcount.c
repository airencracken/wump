#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <stdio.h>
#include <sched.h>

enum { workers = 8, iterations = 100000, seed = 100000000 };
struct fixture {
	PerlInterpreter *interp;
	SV *value;
	pthread_barrier_t barrier;
};

static void *exercise(void *arg) {
	struct fixture *f = (struct fixture *)arg;
	dTHXa(f->interp);
	pthread_barrier_wait(&f->barrier);
	for (int i = 0; i < iterations; i++) {
		SvREFCNT_inc(f->value);
		SvREFCNT_inc_NN(f->value);
		SvREFCNT_inc_void(f->value);
		SvREFCNT_inc_simple_NN(f->value);
		SvREFCNT_inc_void_NN(f->value);
		SvREFCNT_inc_simple_void_NN(f->value);
		if (!(i % 1000)) sched_yield();
		SvREFCNT_dec(f->value);
		SvREFCNT_dec_NN(f->value);
		SvREFCNT_dec(f->value);
		SvREFCNT_dec_NN(f->value);
		SvREFCNT_dec(f->value);
		SvREFCNT_dec_NN(f->value);
	}
	return NULL;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	if (!interp) return 1;
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	char program[] = "refcount-test", option[] = "-e", body[] = "0";
	char *args[] = {program, option, body, NULL};
	if (perl_parse(interp, NULL, 3, args, NULL) || perl_run(interp)) return 1;
	dTHXa(interp);
	struct fixture f;
	f.interp = interp;
	f.value = newSViv(42);
	/* A large permanent root keeps the pre-fix regression from freeing the
	 * counter accidentally. No worker allocates, mutates, or frees SV data. */
	SvREFCNT(f.value) = seed;
	U32 expected = seed + 1;
	if (WUMP_REFCNT_CAS(f.value, expected) || expected != seed
		|| WUMP_REFCNT_LOAD(f.value) != seed) return 1;
	if (!WUMP_REFCNT_CAS(f.value, expected)
		|| WUMP_REFCNT_LOAD(f.value) != seed - 1) return 1;
	WUMP_REFCNT_INC(f.value);
	if (pthread_barrier_init(&f.barrier, NULL, workers)) return 1;
	pthread_t threads[workers];
	for (int i = 0; i < workers; i++) {
		if (pthread_create(&threads[i], NULL, exercise, &f)) {
			fprintf(stderr, "pthread_create failed\n");
			return 1;
		}
	}
	for (int i = 0; i < workers; i++) {
		if (pthread_join(threads[i], NULL)) return 1;
	}
	pthread_barrier_destroy(&f.barrier);
	U32 actual = SvREFCNT(f.value);
	if (actual != seed) {
		fprintf(stderr, "refcount mismatch: expected %u, got %u\n", seed, actual);
		return 1;
	}
	SvREFCNT(f.value) = 1;
	SvREFCNT_dec(f.value);
	perl_destruct(interp);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - 8 native threads preserve the count through 9,600,000 operations");
	return 0;
}
