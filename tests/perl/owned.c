#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static _Thread_local unsigned locks;
extern int __real_pthread_mutex_lock(pthread_mutex_t *);
int __wrap_pthread_mutex_lock(pthread_mutex_t *mutex) {
	locks++;
	return __real_pthread_mutex_lock(mutex);
}

static void private_paths(pTHX_ SV *value) {
	struct wump_shared *claim = NULL;
	CHECK(Perl_wump_memory_shared(aTHX_ value) == -1);
	Perl_wump_memory_check(aTHX_ value);
	CHECK(Perl_wump_read_try_begin(aTHX_ value, &claim) && !claim);
	CHECK(!Perl_wump_mutation_begin(aTHX_ value));
	CHECK(!Perl_wump_capture_begin(aTHX_ value));
	Perl_wump_memory_forget(aTHX_ value);
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	struct wump_perl_task owner = {.interp = interp, .main = 1};
	struct wump_perl_task other = {.interp = interp, .main = 1};
	Perl_wump_task_activate(aTHX_ &owner);
	SV *value = newSViv(42);
	locks = 0;
	private_paths(aTHX_ value);
	CHECK(locks == 0);
	/* An already-held metadata lock needs no extra recursion for a cold
	 * registry probe. The surrounding native region retains its lock. */
	Perl_wump_memory_lock(aTHX);
	locks = 0;
	private_paths(aTHX_ value);
	CHECK(locks == 0);
	Perl_wump_memory_unlock(aTHX);
	/* A failed/cleared publication is a conservative false positive. It
	 * must not manufacture a claim or make an owned value shared. */
	Perl_wump_memory_mark(aTHX_ value, 0);
	private_paths(aTHX_ value);
	ENTER;
	SAVETMPS;
	Perl_wump_publish(aTHX_ value);
	CHECK(Perl_wump_memory_shared(aTHX_ value) == 1);
	locks = 0;
	Perl_wump_publish(aTHX_ value);
	CHECK(locks == 1);
	struct wump_mutation *writer = Perl_wump_mutation_begin(aTHX_ value);
	CHECK(writer);
	Perl_wump_task_activate(aTHX_ &other);
	struct wump_shared *claim = NULL;
	CHECK(!Perl_wump_read_try_begin(aTHX_ value, &claim) && !claim);
	bool busy = FALSE;
	CHECK(!Perl_wump_mutation_try_begin(aTHX_ value, &busy) && busy);
	Perl_wump_task_activate(aTHX_ &owner);
	Perl_wump_mutation_end(aTHX_ writer);
	claim = Perl_wump_read_begin(aTHX_ value);
	CHECK(claim);
	Perl_wump_read_end(aTHX_ claim);
	FREETMPS;
	LEAVE;
	SvREFCNT_dec(value);
	SV *reused = newSViv(99);
	CHECK(reused == value);
	private_paths(aTHX_ reused);
	CHECK(SvIV(reused) == 99);
	SvREFCNT_dec(reused);
	ENTER;
	SAVETMPS;
	SV *registered = newRV_noinc(newSViv(7));
	Perl_wump_memory_mark(aTHX_ registered, 2);
	CHECK(Perl_wump_memory_shared(aTHX_ SvRV(registered)) == -1);
	Perl_wump_publish(aTHX_ registered);
	CHECK(Perl_wump_memory_shared(aTHX_ SvRV(registered)) == 1);
	SvREFCNT_dec(registered);
	FREETMPS;
	LEAVE;
	Perl_wump_task_activate(aTHX_ NULL);
	perl_destruct(interp);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - private probes avoid mutexes; native regions, publication, conflicts and address reuse retain their semantics");
	return 0;
}
