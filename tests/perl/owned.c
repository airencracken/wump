#include "EXTERN.h"
#include "perl.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static _Thread_local unsigned locks;
static unsigned collected;
static SV *collection_source;
static struct wump_borrow *collection_pin;
static struct wump_retired *collection_extra;
extern int __real_pthread_mutex_lock(pthread_mutex_t *);
int __wrap_pthread_mutex_lock(pthread_mutex_t *mutex) {
	locks++;
	return __real_pthread_mutex_lock(mutex);
}

static void private_paths(pTHX_ SV *value) {
	struct wump_shared *claim = NULL;
	CHECK(Perl_wump_memory_shared(aTHX_ value) == -1);
	CHECK(!Perl_wump_readable(aTHX_ value));
	Perl_wump_memory_check(aTHX_ value);
	CHECK(Perl_wump_read_try_begin(aTHX_ value, &claim) && !claim);
	CHECK(!Perl_wump_mutation_begin(aTHX_ value));
	CHECK(!Perl_wump_capture_begin(aTHX_ value));
	Perl_wump_memory_forget(aTHX_ value);
}

static int collection_free(pTHX_ SV *value, MAGIC *magic) {
	PERL_UNUSED_ARG(value);
	PERL_UNUSED_ARG(magic);
	collected++;
	if (collection_extra) {
		/* The outer collector has detached its queue. A destructor may create
		 * another pin and queue more storage before that drain returns. */
		struct wump_retired *extra = collection_extra;
		collection_extra = NULL;
		collection_pin = Perl_wump_capture_begin(aTHX_ collection_source);
		CHECK(collection_pin);
		Perl_wump_retire_commit(aTHX_ extra);
	}
	return 0;
}

static const MGVTBL collection_vtbl = { .svt_free = collection_free };

static struct wump_retired *collection_record(pTHX) {
	SV *value = newSV(0);
	sv_magicext(value, NULL, PERL_MAGIC_ext, &collection_vtbl, NULL, 0);
	struct wump_retired *record = Perl_wump_retire_prepare(aTHX_ value);
	SvREFCNT_dec(value);
	return record;
}

static void collection_paths(pTHX) {
	locks = 0;
	for (int i = 0; i < 32; i++) Perl_wump_memory_collect(aTHX);
	CHECK(!locks && "idle collection must not take a native mutex");
	ENTER;
	SAVETMPS;
	collection_source = newSViv(17);
	Perl_wump_publish(aTHX_ collection_source);
	struct wump_borrow *pin = Perl_wump_capture_begin(aTHX_ collection_source);
	CHECK(pin);
	collection_extra = collection_record(aTHX);
	Perl_wump_retire_commit(aTHX_ collection_record(aTHX));
	size_t pins, pending, nodes;
	Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
	CHECK(pins == 1 && pending == 1 && !collected);
	Perl_wump_memory_collect(aTHX);
	CHECK(!collected);
	Perl_wump_capture_end(aTHX_ pin);
	Perl_wump_memory_collect(aTHX);
	Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
	CHECK(pins == 1 && pending == 1 && collected == 1);
	Perl_wump_memory_collect(aTHX);
	CHECK(collected == 1);
	Perl_wump_capture_end(aTHX_ collection_pin);
	collection_pin = NULL;
	Perl_wump_memory_collect(aTHX);
	Perl_wump_memory_stats(aTHX_ &pins, &pending, &nodes);
	CHECK(!pins && !pending && collected == 2);
	locks = 0;
	Perl_wump_memory_collect(aTHX);
	CHECK(!locks && "a completed drain must restore idle collection");
	SvREFCNT_dec(collection_source);
	collection_source = NULL;
	FREETMPS;
	LEAVE;
}

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc();
	CHECK(interp);
	PERL_SET_CONTEXT(interp);
	perl_construct(interp);
	dTHXa(interp);
	/* Root execution must classify ordinary scalars without the metadata
	 * mutex too; explicit publication still preserves source-cache semantics. */
	SV *root = newSVpvs("42");
	locks = 0;
	CHECK(!Perl_wump_readable(aTHX_ root));
	CHECK(!locks);
	Perl_wump_publish(aTHX_ root);
	locks = 0;
	CHECK(Perl_wump_readable(aTHX_ root));
	CHECK(locks == 1 && "root scalar classification must use one authoritative lookup");
	CHECK(SvIV(root) == 42 && !SvIOK(root));
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
	SvREFCNT_dec(root);
	/* A failed/cleared publication is a conservative false positive. It
	 * must not manufacture a claim or make an owned value shared. */
	Perl_wump_memory_mark(aTHX_ value, 0);
	private_paths(aTHX_ value);
	Perl_wump_memory_mark(aTHX_ value, 1);
	CHECK(!Perl_wump_readable(aTHX_ value));
	ENTER;
	SAVETMPS;
	Perl_wump_publish(aTHX_ value);
	CHECK(Perl_wump_memory_shared(aTHX_ value) == 1);
	locks = 0;
	CHECK(Perl_wump_readable(aTHX_ value));
	CHECK(locks == 2 && "scalar classification and claim must share one lookup, followed by release");
	locks = 0;
	Perl_wump_publish(aTHX_ value);
	CHECK(locks == 1);
	struct wump_mutation *writer = Perl_wump_mutation_begin(aTHX_ value);
	CHECK(writer);
	CHECK(!Perl_wump_readable(aTHX_ value));
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
	ENTER;
	SAVETMPS;
	SV *temporary = sv_2mortal(newSViv(123));
	SvREFCNT_inc(temporary);
	CHECK(SvTEMP(temporary));
	Perl_wump_publish(aTHX_ temporary);
	CHECK(!SvTEMP(temporary));
	FREETMPS;
	CHECK(SvREFCNT(temporary) == 1 && SvIV(temporary) == 123);
	sv_2mortal(SvREFCNT_inc(temporary));
	CHECK(!SvTEMP(temporary));
	FREETMPS;
	CHECK(SvREFCNT(temporary) == 1 && SvIV(temporary) == 123);
	LEAVE;
	SvREFCNT_dec(temporary);
	ENTER;
	SAVETMPS;
	SV *cleared = sv_2mortal(newSViv(456));
	SvREFCNT_inc(cleared);
	SSize_t first_mortal_slot = PL_tmps_ix;
	sv_2mortal(SvREFCNT_inc(cleared));
	/* Argument/assignment paths may clear TEMP while its temporary reference
	 * is still owned by this stack. Publication must transfer that ownership
	 * too, or free_tmps later writes a head another executor is reading. */
	SvTEMP_off(cleared);
	SSize_t mortal_slot = PL_tmps_ix;
	CHECK(PL_tmps_stack[mortal_slot] == cleared);
	Perl_wump_publish(aTHX_ cleared);
	CHECK(PL_tmps_stack[first_mortal_slot] != cleared);
	CHECK(PL_tmps_stack[mortal_slot] != cleared);
	FREETMPS;
	CHECK(SvREFCNT(cleared) == 1 && SvIV(cleared) == 456);
	LEAVE;
	SvREFCNT_dec(cleared);
	collection_paths(aTHX);
	Perl_wump_task_activate(aTHX_ NULL);
	perl_destruct(interp);
	perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - private probes avoid mutexes; native regions, publication, conflicts and address reuse retain their semantics");
	puts("ok - idle collection avoids mutexes and destructor-enqueued storage waits for its last pin");
	return 0;
}
