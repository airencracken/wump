/* Built into the private Perl fork; this cannot be loaded into stock Perl.
 * Acts share one interpreter and never clone it; execution state is private. */
#include "XSUB.h"
#include "wump_runtime_internal.h"
#include <math.h>

/* Header accessors use the executable's ELF TLS slot without caching a
 * native thread address. Keep writes behind the activation API. */
_Thread_local struct wump_perl_task *Perl_wump_task_tls;

/* A coroutine can resume on another native thread. Fetch TLS afresh on
 * every access, and let a nested interpreter retain its own root state. */
__attribute__((noinline)) struct wump_perl_task *Perl_wump_task_current(pTHX) {
	__asm__ volatile("" ::: "memory");
	struct wump_perl_task *task = Perl_wump_task_tls;
	return task && task->interp == aTHX ? task : NULL;
}

void Perl_wump_task_activate(pTHX_ struct wump_perl_task *task) {
	assert(task == NULL || task->interp == aTHX);
	if (task) S_wump_context_mark(aTHX);
	__asm__ volatile("" ::: "memory");
	Perl_wump_task_tls = task;
}

void Perl_wump_checkpoint(pTHX) {
	struct wump_perl_task *task = PL_wump_task;
	/* The compiler and auxiliary callback stacks still use shared state.
	 * Only ordinary runtime op boundaries are automatic scheduling points.
	 * Teardown cannot resume abandoned C frames or schedule destructors. */
	if (task && task->initialized && !task->finished && PL_phase == PERL_PHASE_RUN
		&& !task->critical
		&& !PL_parser && PL_curstackinfo->si_type == PERLSI_MAIN
		&& !Perl_wump_publish_active(aTHX)) {
		wump_checkpoint();
	}
}

int Perl_wump_runops(pTHX) {
	unsigned ticks = 256;
	OP *op = PL_op;
	bool parallel = wump_nprocs() > 1;
	PERL_DTRACE_PROBE_OP(op);
	while (op) {
		PL_op = op;
		if (parallel && (op->op_type == OP_ENTEREVAL || op->op_type == OP_REQUIRE
			|| op->op_type == OP_DOFILE))
			croak("Wump: runtime compilation is not supported during parallel execution");
		op = op->op_ppaddr(aTHX);
		PL_op = op;
		if (!op) break;
		if (--ticks == 0) {
			ticks = 256;
			Perl_wump_checkpoint(aTHX);
		}
		PERL_DTRACE_PROBE_OP(op);
	}
	PERL_ASYNC_CHECK();
	TAINT_NOT;
	return 0;
}

#include "wump_memory.c"
#include "wump_publish.c"
#include "wump_local.c"
#include "wump_elements.c"
#include "wump_lvalues.c"
#include "wump_magic.c"

typedef struct wump_cv_slot {
	CV *cv;
	PADLIST *pad;
	I32 depth;
	struct wump_cv_slot *next;
} wump_cv_slot;

enum wump_regex_kind { WUMP_REGEX_PM, WUMP_REGEX_NAMES, WUMP_REGEX_HASH, WUMP_REGEX_SCALAR };
typedef struct wump_regex_slot {
	uint64_t id;
	enum wump_regex_kind kind;
	SV *value;
	SV *origin;
	REGEXP *native_copy;
	bool ready;
	struct wump_regex_slot *next;
} wump_regex_slot;

static _Atomic uint64_t wump_regex_sequence;

void Perl_wump_pm_stamp(pTHX_ PMOP *pm) {
	uint64_t previous = atomic_load_explicit(&wump_regex_sequence, memory_order_relaxed);
	for (;;) {
		if (previous == UINT64_MAX) croak("Wump: regex identity space exhausted");
		if (atomic_compare_exchange_weak_explicit(&wump_regex_sequence, &previous,
			previous + 1, memory_order_relaxed, memory_order_relaxed)) break;
	}
	pm->op_wump_id = previous + 1;
	pm->op_wump_runtime = 0;
}

static wump_regex_slot *wump_regex_find(pTHX_ PMOP *pm) {
	for (wump_regex_slot *slot = PL_wump_task->regexes; slot != NULL; slot = slot->next) {
		if (slot->kind == WUMP_REGEX_PM && slot->id == pm->op_wump_id) return slot;
	}
	return NULL;
}

SV **Perl_wump_pm_slot(pTHX_ PMOP *pm) {
	if (PL_wump_task == NULL) return &PL_regex_pad[pm->op_pmoffset];
	assert(pm->op_wump_id != 0);
	wump_regex_slot *slot = wump_regex_find(aTHX_ pm);
	if (slot != NULL) return &slot->value;
	Newxz(slot, 1, wump_regex_slot);
	slot->id = pm->op_wump_id;
	SV *original = PL_regex_pad[pm->op_pmoffset];
	if (!pm->op_wump_runtime && original != NULL && SvTYPE(original) == SVt_REGEXP) {
		slot->value = (SV *)reg_temp_copy(NULL, (REGEXP *)original);
		if (!ReANY((REGEXP *)original)->mother_re) slot->native_copy = (REGEXP *)slot->value;
	} else {
		/* Each task starts its own runtime /o and ordinary pattern cache. */
		slot->value = &PL_sv_undef;
	}
	slot->next = PL_wump_task->regexes;
	PL_wump_task->regexes = slot;
	return &slot->value;
}

REGEXP *Perl_wump_pm_get(pTHX_ PMOP *pm) {
	SV *value = *Perl_wump_pm_slot(aTHX_ pm);
	return value != NULL && SvTYPE(value) == SVt_REGEXP ? (REGEXP *)value : NULL;
}

bool Perl_wump_pm_native(pTHX_ PMOP *pm, REGEXP *rx) {
	if (PL_wump_task == NULL) return FALSE;
	wump_regex_slot *slot = wump_regex_find(aTHX_ pm);
	return slot != NULL && slot->native_copy == rx;
}

static wump_regex_slot *wump_regex_hash(pTHX_ HV *original,
	enum wump_regex_kind kind, MAGIC *tied) {
	for (wump_regex_slot *slot = PL_wump_task->regexes; slot != NULL; slot = slot->next) {
		if (slot->kind == kind && slot->origin == (SV *)original) return slot;
	}
	wump_regex_slot *slot;
	Newxz(slot, 1, wump_regex_slot);
	HV *copy;
	if (tied != NULL) {
		copy = newHV();
		sv_magicext((SV *)copy, tied->mg_obj, PERL_MAGIC_tied, tied->mg_virtual, NULL, 0);
	} else {
		/* newHVhv preserves the source iterator and copies its metadata. */
		copy = newHVhv(original);
	}
	slot->kind = kind;
	slot->origin = SvREFCNT_inc((SV *)original);
	slot->value = (SV *)copy;
	slot->next = PL_wump_task->regexes;
	PL_wump_task->regexes = slot;
	return slot;
}

HV *Perl_wump_regex_names(pTHX_ HV *original) {
	if (PL_wump_task == NULL || original == NULL) return original;
	return (HV *)wump_regex_hash(aTHX_ original, WUMP_REGEX_NAMES, NULL)->value;
}

static MAGIC *wump_named_capture_tie(pTHX_ HV *hash) {
	/* HvNAME reads stash head flags, including the word updated by overload
	 * cache discovery. Classify under its metadata lock, then release it
	 * before allocating an act's private capture hash. No callbacks here. */
	bool guarded = Perl_wump_parallel(aTHX);
	if (guarded) Perl_wump_memory_lock(aTHX);
	MAGIC *tied = NULL;
	if (!hash || !SvMAGICAL(hash)) goto done;
	tied = mg_find((SV *)hash, PERL_MAGIC_tied);
	if (tied == NULL || tied->mg_obj == NULL || !SvROK(tied->mg_obj)) {
		tied = NULL;
		goto done;
	}
	SV *object = SvRV(tied->mg_obj);
	if (!SvOBJECT(object)) { tied = NULL; goto done; }
	const char *name = HvNAME(SvSTASH(object));
	if (name == NULL || strNE(name, "Tie::Hash::NamedCapture")) tied = NULL;
done:
	if (guarded) Perl_wump_memory_unlock(aTHX);
	return tied;
}

HV **Perl_wump_gv_hv(GV *gv) {
	dTHX;
	wump_local *binding = wump_local_find(aTHX_ gv, 'h', FALSE);
	if (binding != NULL) return (HV **)&binding->value;
	HV **original = &GvGP(gv)->gp_hv;
	if (PL_wump_task == NULL) return original;
	Perl_wump_publish(aTHX_ (SV *)*original);
	MAGIC *tied = wump_named_capture_tie(aTHX_ *original);
	if (tied == NULL) return original;
	/* The builtin tie object only stores immutable API flags. The hash
	 * itself owns each() state, so %+ / %- and aliases need private HVs. */
	return (HV **)&wump_regex_hash(aTHX_ *original, WUMP_REGEX_HASH, tied)->value;
}

typedef struct wump_perl_message {
	SV *value;
	struct wump_perl_message *next, *previous;
} wump_perl_message;

typedef struct wump_perl_channel {
	UV id;
	wump_chan *ch;
	struct wump_perl_channel *next;
} wump_perl_channel;

typedef struct wump_perl_run {
	struct wump_perl_allocator *allocators;
	int nprocs;
	pthread_mutex_t registry;
	wump_perl_channel *channels;
	wump_perl_message *messages;
	struct wump_perl_waitgroup *groups;
	struct wump_perl_lock *locks;
	SV *panic;
	UV panic_task;
	_Atomic UV next_task;
	int started;
	int status;
} wump_perl_run;

static wump_perl_run *wump_perl_active;
static _Atomic UV wump_channel_id;

static UV wump_next_id(pTHX_ _Atomic UV *sequence, const char *kind) {
	UV previous = atomic_load_explicit(sequence, memory_order_relaxed);
	for (;;) {
		if (previous == UV_MAX) croak("Wump: %s id space exhausted", kind);
		if (atomic_compare_exchange_weak_explicit(sequence, &previous, previous + 1,
			memory_order_relaxed, memory_order_relaxed)) return previous + 1;
	}
}

static void wump_registry_lock(void) {
	if (pthread_mutex_lock(&wump_perl_active->registry)) abort();
}

static void wump_registry_unlock(void) {
	if (pthread_mutex_unlock(&wump_perl_active->registry)) abort();
}

void Perl_wump_panic(pTHX_ SV *error) {
	SV *copy = newSVsv(error);
	wump_registry_lock();
	if (!wump_perl_active->panic) {
		wump_perl_active->panic = copy;
		wump_perl_active->panic_task = PL_wump_task->id;
		copy = NULL;
	}
	wump_registry_unlock();
	SvREFCNT_dec(copy);
	wump_halt(ECANCELED);
}

#include "wump_waitgroup.c"

#include "wump_lock.c"

static wump_cv_slot *wump_cv_find(pTHX_ const CV *cv) {
	if (PL_wump_task != NULL) {
		for (wump_cv_slot *slot = PL_wump_task->cvs; slot != NULL; slot = slot->next) {
			if (slot->cv == cv) return slot;
		}
	}
	return NULL;
}

I32 *Perl_wump_cv_depth(pTHX_ const CV *cv) {
	wump_cv_slot *slot = wump_cv_find(aTHX_ cv);
	return slot != NULL ? &slot->depth : &((XPVCV *)SvANY(cv))->xcv_depth;
}

PADLIST **Perl_wump_cv_padlist(CV *cv) {
	dTHX;
	wump_cv_slot *slot = wump_cv_find(aTHX_ cv);
	return slot != NULL ? &slot->pad : &((XPVCV *)SvANY(cv))->xcv_padlist_u.xcv_padlist;
}

/* Reuse Perl's recursive-pad construction to preserve captured/state
 * lexicals and constants while allocating fresh local variables and @_. */
void Perl_wump_cv_prepare(pTHX_ CV *cv) {
	if (PL_wump_task == NULL ||
		CvISXSUB(cv) || wump_cv_find(aTHX_ cv) != NULL) return;
	Perl_wump_publish(aTHX_ (SV *)cv);
	PADLIST *original = CvPADLIST(cv);
	if (original == NULL) return;
	wump_cv_slot *slot;
	PADLIST *pad;
	Newxz(slot, 1, wump_cv_slot);
	Newxz(pad, 1, PADLIST);
	Newxz(PadlistARRAY(pad), 2, PAD *);
	PadlistMAX(pad) = 1;
	pad->xpadl_id = original->xpadl_id;
	pad->xpadl_outid = original->xpadl_outid;
	PadlistNAMES(pad) = PadnamelistREFCNT_inc(PadlistNAMES(original));
	PadlistARRAY(pad)[1] = (PAD *)SvREFCNT_inc(PadlistARRAY(original)[1]);
	pad_push(pad, 2);
	SvREFCNT_dec(PadlistARRAY(pad)[1]);
	PadlistARRAY(pad)[1] = PadlistARRAY(pad)[2];
	PadlistARRAY(pad)[2] = NULL;
	/* Keep max=2: the allocated array really has three entries. */
	slot->pad = pad;
	slot->cv = CvREFCNT_inc(cv);
	slot->next = PL_wump_task->cvs;
	PL_wump_task->cvs = slot;
}

static void wump_regex_scalar_abort(pTHX_ void *arg) {
	wump_regex_slot *slot = arg;
	if (slot->ready) return;
	wump_regex_slot **link = (wump_regex_slot **)&PL_wump_task->regexes;
	while (*link && *link != slot) link = &(*link)->next;
	if (*link) *link = slot->next;
	SV *value = slot->value, *origin = slot->origin;
	Safefree(slot);
	SvREFCNT_dec(value);
	SvREFCNT_dec(origin);
}

static SV **wump_regex_scalar(pTHX_ GV *gv) {
	/* Use the effective glob so aliases share one cell. Check its immutable
	 * name before touching a scalar: ordinary package values may be changing
	 * on another act. These are the names magicalized as match results. */
	GV *effective = GvEGV(gv) ? GvEGV(gv) : gv;
	const char *name = GvNAME(effective);
	STRLEN length = GvNAMELEN(effective);
	bool numbered = length && name[0] >= '1' && name[0] <= '9';
	for (STRLEN i = 1; numbered && i < length; i++)
		if (name[i] < '0' || name[i] > '9') numbered = FALSE;
	bool named = length == 1 && (name[0] == '&' || name[0] == '`'
		|| name[0] == '\'' || name[0] == '+' || name[0] == '\016');
	if (!numbered && !named && !memEQs(name, length, "\015ATCH")
		&& !memEQs(name, length, "\020REMATCH") && !memEQs(name, length, "\020OSTMATCH")
		&& !memEQs(name, length, "\014AST_SUCCESSFUL_PATTERN")) return NULL;
	SV *original = GvGP(gv)->gp_sv;
	if (!original) return NULL;
	Perl_wump_memory_check(aTHX_ original);
	if (SvTYPE(original) < SVt_PVMG) return NULL;
	MAGIC *magic;
	for (magic = SvMAGIC(original); magic; magic = magic->mg_moremagic) {
		if (magic->mg_type != PERL_MAGIC_sv || magic->mg_virtual != &PL_vtbl_sv) continue;
		if (!magic->mg_ptr || (magic->mg_len == 1
			&& (magic->mg_ptr[0] == '+' || magic->mg_ptr[0] == '\016'))
			|| memEQs(magic->mg_ptr, magic->mg_len, "\014AST_SUCCESSFUL_PATTERN")) break;
	}
	if (!magic) return NULL;
	for (wump_regex_slot *slot = PL_wump_task->regexes; slot; slot = slot->next)
		if (slot->kind == WUMP_REGEX_SCALAR && slot->origin == original) return &slot->value;
	SSCHECK(3);
	I32 mark = PL_savestack_ix;
	wump_regex_slot *slot;
	Newxz(slot, 1, wump_regex_slot);
	SAVEDESTRUCTOR_X(wump_regex_scalar_abort, slot);
	slot->kind = WUMP_REGEX_SCALAR;
	slot->origin = SvREFCNT_inc(original);
	slot->value = newSV(0);
	/* sv_magicext checks the owning GV's scalar slot. Install our cell
	 * first so that recursive lookup returns it rather than creating again. */
	slot->next = PL_wump_task->regexes;
	PL_wump_task->regexes = slot;
	/* Native get-magic reads this act's current match. Its result cache
	 * must also be private; a shared GV cell races even with private PMOPs. */
	sv_magic(slot->value, magic->mg_obj, PERL_MAGIC_sv, magic->mg_ptr, magic->mg_len);
	if (SvREADONLY(original)) SvREADONLY_on(slot->value);
	slot->ready = TRUE;
	LEAVE_SCOPE(mark);
	return &slot->value;
}

SV **Perl_wump_gv_sv(GV *gv) {
	dTHX;
	wump_local *binding = wump_local_find(aTHX_ gv, 's', FALSE);
	if (binding != NULL) return &binding->value;
	if (PL_wump_task != NULL) {
		SV **capture = wump_regex_scalar(aTHX_ gv);
		if (capture) return capture;
		if (gv == aTHX->Idefgv) gv = PL_defgv;
		else if (gv == aTHX->Ierrgv) gv = PL_errgv;
		else if (gv == aTHX->Ireplgv) gv = PL_replgv;
		if (gv != PL_defgv && gv != PL_errgv && gv != PL_replgv)
			Perl_wump_publish(aTHX_ GvGP(gv)->gp_sv);
	}
	return &GvGP(gv)->gp_sv;
}

AV **Perl_wump_gv_av(GV *gv) {
	dTHX;
	wump_local *binding = wump_local_find(aTHX_ gv, 'a', FALSE);
	if (binding != NULL) return (AV **)&binding->value;
	if (PL_wump_task != NULL && gv == aTHX->Idefgv) gv = PL_defgv;
	if (PL_wump_task && gv != PL_defgv) Perl_wump_publish(aTHX_ (SV *)GvGP(gv)->gp_av);
	return &GvGP(gv)->gp_av;
}

static void wump_perl_enter(void *arg) {
	struct wump_perl_task *task = arg;
	/* SET_CONTEXT consults execution phase while restoring libc's locale.
	 * Select this act before it can inspect the interpreter's root fields. */
	Perl_wump_task_activate(task->interp, task);
	int worker = wump_worker_id();
	/* Shutdown frees abandoned acts after every executor has joined. */
	if (worker < 0) worker = 0;
	assert(worker < wump_perl_active->nprocs);
	Perl_wump_allocator_activate(task->interp, &wump_perl_active->allocators[worker]);
	PERL_SET_CONTEXT(task->interp);
}

static void wump_perl_caches_free(pTHX_ struct wump_perl_task *task) {
	/* Dropping a pad or regex may run a destructor which calls another CV
	 * or creates match state. Keep those calls private too, and drain any
	 * new entries before releasing the act's Perl stacks. */
	while (task->cvs || task->regexes) {
		if (task->cvs) {
			wump_cv_slot *slot = task->cvs;
			task->cvs = slot->next;
			for (SSize_t n = PadlistMAX(slot->pad); n > 0; n--)
				SvREFCNT_dec(PadlistARRAY(slot->pad)[n]);
			PadnamelistREFCNT_dec(PadlistNAMES(slot->pad));
			Safefree(PadlistARRAY(slot->pad));
			Safefree(slot->pad);
			SvREFCNT_dec(slot->cv);
			Safefree(slot);
		} else {
			wump_regex_slot *slot = task->regexes;
			task->regexes = slot->next;
			SV *value = slot->value, *origin = slot->origin;
			Safefree(slot);
			SvREFCNT_dec(value);
			SvREFCNT_dec(origin);
		}
	}
}

static void wump_perl_task_free(void *arg) {
	struct wump_perl_task *task = arg;
	dTHXa(task->interp);
	wump_perl_enter(task);
	if (!task->initialized) {
		/* A queued task has no Perl stacks on which to free its CV. */
		Perl_wump_task_activate(aTHX_ NULL);
		wump_local_clear(aTHX_ task);
		SvREFCNT_dec(task->entry);
		Safefree(task);
		return;
	}
	int abandoned = !task->finished;
	/* Destructors may call Perl, but cannot schedule during teardown.
	 * Finished acts can be reclaimed concurrently, so their callbacks must
	 * keep private CV frames rather than modifying the original CV depth. */
	task->finished = 2;
	if (task->initialized) {
		/* Abandoned XS frames still have mapped C stacks at this point.
		 * Catch destructor failures locally rather than jumping into one. */
		dJMPENV;
		JMPENV_BOOTSTRAP;
		int jump;
		JMPENV_PUSH(jump);
		if (jump == 0 && abandoned) {
			dounwind(-1);
			LEAVE_SCOPE(0);
			PL_tmps_floor = -1;
			free_tmps();
		}
		JMPENV_POP;
		if (jump != 0) {
			PerlIO_printf(Perl_error_log, "Wump: task destructor failed during shutdown\n");
		}
		wump_perl_caches_free(aTHX_ task);
		SvREFCNT_dec(task->entry);
		task->entry = NULL;
		wump_local_clear(aTHX_ task);
		if (!task->main) {
			GV *defgv = PL_defgv;
			GV *errgv = PL_errgv;
			GV *replgv = PL_replgv;
			PL_defgv = aTHX->Idefgv;
			PL_errgv = aTHX->Ierrgv;
			PL_replgv = aTHX->Ireplgv;
			SvREFCNT_dec(defgv);
			SvREFCNT_dec(errgv);
			SvREFCNT_dec(replgv);
		}
		wump_perl_caches_free(aTHX_ task);
		/* The main act borrows the interpreter's original Perl stacks.
		 * perl_destruct owns those stacks after scheduler shutdown. */
		if (task->main) {
			Perl_wump_task_activate(aTHX_ NULL);
			Safefree(task);
			return;
		}
		SvREFCNT_dec(PL_stashcache);
		PL_stashcache = NULL;
		Perl_free_tied_hv_pool(aTHX);
		wump_perl_caches_free(aTHX_ task);
		if (PL_reg_curpm != NULL) {
			IV offset = PL_reg_curpm->op_pmoffset;
			/* The fake PMOP was allocated by regexec, not newPMOP. Its
			 * template is undef; return the global offset to Perl's pool. */
			SvREFCNT_dec(PL_regex_pad[offset]);
			PL_regex_pad[offset] = &PL_sv_undef;
			sv_catpvn_nomg(PL_regex_pad[0], (const char *)&offset, sizeof(offset));
			if (PL_curpm == PL_reg_curpm) PL_curpm = NULL;
			if (PL_curpm_under == PL_reg_curpm) PL_curpm_under = NULL;
			Safefree(PL_reg_curpm);
			PL_reg_curpm = NULL;
		}
		while (PL_curstackinfo->si_next != NULL) PL_curstackinfo = PL_curstackinfo->si_next;
		while (PL_curstackinfo != NULL) {
			PERL_SI *previous = PL_curstackinfo->si_prev;
			SvREFCNT_dec(PL_curstackinfo->si_stack);
			Safefree(PL_curstackinfo->si_cxstack);
			Safefree(PL_curstackinfo);
			PL_curstackinfo = previous;
		}
		Safefree(PL_tmps_stack);
		Safefree(PL_markstack);
		Safefree(PL_scopestack);
#ifdef DEBUGGING
		Safefree(PL_scopestack_name);
#endif
		Safefree(PL_savestack);
		regmatch_slab *slab = PL_regmatch_slab;
		while (slab != NULL) {
			regmatch_slab *next = slab->next;
			Safefree(slab);
			slab = next;
		}
	}
	Perl_wump_task_activate(aTHX_ NULL);
	Safefree(task);
}

static void wump_perl_new_abort(pTHX_ void *arg) {
	struct wump_perl_task *task = arg;
	if (task->id != 0) return;
	wump_local_clear(aTHX_ task);
	SvREFCNT_dec(task->entry);
	Safefree(task);
}

static struct wump_perl_task *wump_perl_task_new(pTHX_ SV *callback) {
	if (!SvROK(callback) || SvTYPE(SvRV(callback)) != SVt_PVCV) croak("Wump: expected a code reference");
	struct wump_perl_task *task;
	Newxz(task, 1, struct wump_perl_task);
	task->interp = aTHX;
	task->entry = CvREFCNT_inc((CV *)SvRV(callback));
	task->Iphase = PERL_PHASE_RUN;
	task->Icurcop = PL_curcop;
	task->Icurstash = PL_curstash;
	task->Idefoutgv = PL_defoutgv;
	task->Imaxsysfd = PL_maxsysfd;
	I32 mark = PL_savestack_ix;
	SAVEDESTRUCTOR_X(wump_perl_new_abort, task);
	wump_local_snapshot(aTHX_ task);
	if (PL_wump_task) {
		Perl_wump_publish(aTHX_ (SV *)task->entry);
		/* Snapshot containers/cells are private to the child; only values
		 * reached through their references escape the parent. */
		for (wump_local *slot = task->locals; slot; slot = slot->next) {
			Perl_wump_publish_snapshot(aTHX_ slot->value);
		}
		for (wump_element *slot = task->elements; slot; slot = slot->next) {
			Perl_wump_publish_snapshot(aTHX_ slot->value);
			Perl_wump_publish_snapshot(aTHX_ (SV *)slot->cell);
		}
	}
	task->id = wump_next_id(aTHX_ &wump_perl_active->next_task, "task");
	LEAVE_SCOPE(mark);
	return task;
}

static void wump_perl_task_start(void *arg) {
	struct wump_perl_task *task = arg;
	dTHXa(task->interp);
	wump_perl_enter(task);
	if (task->id == 1) {
		wump_perl_active->started = 1;
		if (wump_context_attach(wump_perl_enter, wump_perl_task_free, task) != 0) abort();
	}
	if (task->main) {
		task->initialized = 1;
		wump_perl_active->status = perl_run(aTHX);
		task->finished = 1;
		return;
	}
	JMPENV_BOOTSTRAP;
	init_stacks();
	task->initialized = 1;
	PL_stashcache = newHV();
	/* gv_init treats an already typed SV as a subroutine prototype. These
	 * slots are private cells, with no namespace/backreference membership. */
	PL_defgv = (GV *)newSV(0);
	gv_init(PL_defgv, NULL, "_", 1, 0);
	if (GvGP(PL_defgv)->gp_sv == NULL) GvGP(PL_defgv)->gp_sv = newSV(0);
	GvGP(PL_defgv)->gp_av = newAV();
	PL_errgv = (GV *)newSV(0);
	gv_init(PL_errgv, NULL, "@", 1, 0);
	if (GvGP(PL_errgv)->gp_sv == NULL) GvGP(PL_errgv)->gp_sv = newSVpvs("");
	PL_replgv = (GV *)newSV(0);
	gv_init(PL_replgv, NULL, "\022", 1, 0);
	if (GvGP(PL_replgv)->gp_sv == NULL) GvGP(PL_replgv)->gp_sv = newSV(0);
	{
		dSP;
		ENTER;
		SAVETMPS;
		PUSHMARK(SP);
		PUTBACK;
		call_sv((SV *)task->entry, G_DISCARD | G_EVAL);
		if (SvTRUE(ERRSV) || SvROK(ERRSV)) {
			Perl_wump_panic(aTHX_ ERRSV);
		}
		FREETMPS;
		LEAVE;
	}
	task->finished = 1;
}

int Perl_wump_main(pTHX) {
	if (wump_perl_active != NULL) croak("Wump: another interpreter runtime is active");
	wump_perl_run run = {0};
	run.nprocs = 1;
	const char *procs = getenv("WUMPPROCS");
	if (procs) {
		unsigned count = 0;
		for (const char *p = procs; *p; p++) {
			if (*p < '0' || *p > '9' || count > 256)
				croak("Wump: WUMPPROCS must be an integer from 1 to 256");
			count = count * 10 + (unsigned)(*p - '0');
		}
		if (!count || count > 256) croak("Wump: WUMPPROCS must be an integer from 1 to 256");
		run.nprocs = (int)count;
	}
	if (run.nprocs > 1 && PL_runops != Perl_runops_standard)
		croak("Wump: custom runloops are not supported during parallel execution");
#ifdef DEBUGGING
	if (run.nprocs > 1 && PL_debug) croak("Wump: debug runloops are not supported during parallel execution");
#endif
	Newxz(run.allocators, run.nprocs, struct wump_perl_allocator);
	for (int i = 0; i < run.nprocs; i++) Perl_wump_allocator_init(aTHX_ &run.allocators[i]);
	if (pthread_mutex_init(&run.registry, NULL)) {
		Safefree(run.allocators);
		croak("Wump: cannot initialize runtime registry");
	}
	struct wump_perl_task *task;
	Newxz(task, 1, struct wump_perl_task);
	wump_perl_active = &run;
	task->interp = aTHX;
	task->id = wump_next_id(aTHX_ &run.next_task, "task");
	task->main = 1;
	/* perlmain normally defers END until perl_destruct. Run it while
	 * the main act, its match state, and the scheduler are still alive. */
	U8 destruct_end = PL_exit_flags & PERL_EXIT_DESTRUCT_END;
	PL_exit_flags &= ~PERL_EXIT_DESTRUCT_END;
	int result = wump_run(wump_perl_task_start, task, run.nprocs);
	int error = wump_errno();
	PL_exit_flags |= destruct_end;
	Perl_wump_task_activate(aTHX_ NULL);
	Perl_wump_allocator_activate(aTHX_ NULL);
	for (int i = 0; i < run.nprocs; i++) Perl_wump_allocator_merge(aTHX_ &run.allocators[i]);
	Safefree(run.allocators);
	if (pthread_mutex_destroy(&run.registry)) abort();
	/* Startup can fail before the task has attached its cleanup hook. */
	if (!run.started) {
		Safefree(task);
	}
	wump_perl_active = NULL;
	while (run.channels != NULL) {
		wump_perl_channel *next = run.channels->next;
		wump_chan_free(run.channels->ch);
		Safefree(run.channels);
		run.channels = next;
	}
	while (run.messages != NULL) {
		wump_perl_message *next = run.messages->next;
		SvREFCNT_dec(run.messages->value);
		Safefree(run.messages);
		run.messages = next;
	}
	while (run.groups != NULL) {
		wump_perl_waitgroup *next = run.groups->next;
		wump_waitgroup_free(run.groups);
		run.groups = next;
	}
	if (run.panic != NULL) {
		PerlIO_printf(Perl_error_log, "task %" UVuf " [panic]: %s", run.panic_task, SvPV_nolen(run.panic));
		SvREFCNT_dec(run.panic);
		PerlIO_flush(NULL);
		exit(2);
	}
	if (result != 0) {
		PerlIO_printf(Perl_error_log, "Wump: runtime failed: %s\n", Strerror(error));
		STATUS_EXIT_SET(2);
		return 2;
	}
	return run.status;
}

static void xs_wump_enable(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 0) croak("Usage: Wump::_enable()");
	if (PL_phase >= PERL_PHASE_RUN && !PL_wump_task)
		croak("Wump: enable with use Wump before program execution");
	/* Reject unsupported allocator diagnostics on Perl's compilation
	 * stack, before scheduler context hooks can run. */
#if defined(MYMALLOC) || defined(PERL_TRACK_MEMPOOL) || defined(DEBUG_LEAKING_SCALARS)
	croak("Wump: executor arenas require system malloc without Perl memory tracking");
#endif
#ifdef PERL_DEBUG_READONLY_COW
	croak("Wump: concurrent COW ownership does not support read-only COW diagnostics");
#endif
#ifdef DEBUGGING
	if (DEBUG_D_TEST) croak("Wump: executor arenas do not support -DD arena scans");
#endif
	aTHX->Iwump_enabled = TRUE;
	XSRETURN_EMPTY;
}

static void xs_wump_act(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: act requires a running task and a code reference");
	struct wump_perl_task *task = wump_perl_task_new(aTHX_ ST(0));
	if (wump_go_context(wump_perl_task_start, task, wump_perl_enter, wump_perl_task_free) != 0) {
		wump_local_clear(aTHX_ task);
		SvREFCNT_dec(task->entry);
		Safefree(task);
		croak("Wump: spawn failed");
	}
	XSRETURN_EMPTY;
}

static wump_perl_channel *wump_perl_channel_get(pTHX_ SV *object) {
	if (wump_perl_active == NULL || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: channel operation requires a running task");
	if (!SvROK(object) || !sv_derived_from(object, "Wump::Channel") || SvTYPE(SvRV(object)) >= SVt_PVAV) croak("Wump: invalid channel");
	UV id = SvUV(SvRV(object));
	wump_registry_lock();
	wump_perl_channel *found = NULL;
	for (wump_perl_channel *ch = wump_perl_active->channels; ch; ch = ch->next) {
		if (ch->id == id) { found = ch; break; }
	}
	wump_registry_unlock();
	if (found) return found;
	croak("Wump: channel belongs to an inactive runtime");
}

static void xs_wump_chan(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: chan requires a running task");
	if (!SvOK(ST(0)) || SvROK(ST(0)) || !looks_like_number(ST(0))) croak("Wump: invalid channel capacity");
	NV capacity = SvNV(ST(0));
	if (!isfinite(capacity) || capacity < 0 || capacity > INT_MAX || capacity != (NV)(IV)capacity) croak("Wump: invalid channel capacity");
	UV channel_id = wump_next_id(aTHX_ &wump_channel_id, "channel");
	wump_perl_channel *ch;
	Newxz(ch, 1, wump_perl_channel);
	ch->ch = wump_chan_make(sizeof(wump_perl_message *), (size_t)capacity);
	if (ch->ch == NULL) { Safefree(ch); croak("Wump: channel allocation failed"); }
	ch->id = channel_id;
	wump_registry_lock();
	ch->next = wump_perl_active->channels;
	wump_perl_active->channels = ch;
	wump_registry_unlock();
	SV *id = newSVuv(ch->id);
	SV *object = newRV_noinc(id);
	sv_bless(object, gv_stashpvs("Wump::Channel", GV_ADD));
	SvREADONLY_on(id);
	ST(0) = sv_2mortal(object);
	XSRETURN(1);
}

static void xs_wump_send(pTHX_ CV *cv) {
	dXSARGS;
	wump_schedule_check(aTHX);
	if (items != 2) croak("Usage: CHANNEL->send(VALUE)");
	wump_perl_channel *ch = wump_perl_channel_get(aTHX_ ST(0));
	wump_perl_message *message;
	Newxz(message, 1, wump_perl_message);
	wump_registry_lock();
	message->next = wump_perl_active->messages;
	if (message->next != NULL) message->next->previous = message;
	wump_perl_active->messages = message;
	wump_registry_unlock();
	message->value = newSVsv(ST(1));
	Perl_wump_publish(aTHX_ message->value);
	if (wump_chan_send(ch->ch, &message) != 0) croak("Wump: send on closed channel");
	XSRETURN_EMPTY;
}

static void xs_wump_recv(pTHX_ CV *cv) {
	dXSARGS;
	wump_schedule_check(aTHX);
	if (items != 1) croak("Usage: CHANNEL->recv()");
	wump_perl_channel *ch = wump_perl_channel_get(aTHX_ ST(0));
	wump_perl_message *message = NULL;
	int result = wump_chan_recv(ch->ch, &message);
	if (result < 0) croak("Wump: receive failed");
	if (result == 0) {
		ST(0) = &PL_sv_undef;
		if (GIMME_V == G_LIST) { EXTEND(SP, 1); ST(1) = &PL_sv_no; XSRETURN(2); }
		XSRETURN(1);
	}
	ST(0) = sv_2mortal(newSVsv(message->value));
	SvREFCNT_dec(message->value);
	wump_registry_lock();
	if (message->previous != NULL) message->previous->next = message->next;
	else wump_perl_active->messages = message->next;
	if (message->next != NULL) message->next->previous = message->previous;
	wump_registry_unlock();
	Safefree(message);
	if (GIMME_V == G_LIST) { EXTEND(SP, 1); ST(1) = &PL_sv_yes; XSRETURN(2); }
	XSRETURN(1);
}

static void xs_wump_close(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: CHANNEL->close()");
	wump_perl_channel *ch = wump_perl_channel_get(aTHX_ ST(0));
	if (wump_chan_close(ch->ch) != 0) croak("Wump: close of closed channel");
	XSRETURN_EMPTY;
}

static void xs_wump_yield(pTHX_ CV *cv) {
	dXSARGS;
	wump_schedule_check(aTHX);
	if (items != 0 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: yield requires a running task");
	wump_yield();
	XSRETURN_EMPTY;
}

static void xs_wump_sleep(pTHX_ CV *cv) {
	dXSARGS;
	wump_schedule_check(aTHX);
	if (items != 1 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: sleep requires a running task");
	if (!SvOK(ST(0)) || SvROK(ST(0)) || !looks_like_number(ST(0))) croak("Wump: invalid sleep duration");
	NV duration = SvNV(ST(0));
	if (!isfinite(duration) || duration < 0 || duration >= (NV)INT64_MAX / 1e9) croak("Wump: invalid sleep duration");
	if (wump_sleep((int64_t)(duration * 1e9)) != 0) croak("Wump: sleep failed");
	XSRETURN_EMPTY;
}

static void xs_wump_execution_slots(pTHX_ CV *cv) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items || !PL_wump_task || !wump_self())
		croak("Wump: execution_slots requires a running act and no arguments");
	ST(0) = sv_2mortal(newSViv(wump_nprocs()));
	XSRETURN(1);
}

void Perl_wump_boot(pTHX) {
	Perl_wump_xs_allow(aTHX_ newXS("Wump::execution_slots", xs_wump_execution_slots, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_enable", xs_wump_enable, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_waitgroup", xs_wump_waitgroup, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_wg_add", xs_wump_wg_add, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_wg_done", xs_wump_wg_done, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_wg_wait", xs_wump_wg_wait, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_wg_destroy", xs_wump_wg_destroy, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::is_shared", xs_wump_is_shared, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_act", xs_wump_act, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_chan", xs_wump_chan, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_send", xs_wump_send, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_recv", xs_wump_recv, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_close", xs_wump_close, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_yield", xs_wump_yield, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("Wump::_sleep", xs_wump_sleep, __FILE__));
}
