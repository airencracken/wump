/* One conservative reclamation domain per interpreter. Only short metadata
 * operations hold this mutex. A logical mutation claim belongs to an act,
 * survives parking/migration, and never holds an OS mutex across a callback. */
#include <stdatomic.h>
#include <pthread.h>

enum { WUMP_MEMORY_BUCKETS = 4096, WUMP_MEMORY_FILTER_SHIFT = 14,
	WUMP_MEMORY_FILTER_WORDS = 1 << WUMP_MEMORY_FILTER_SHIFT,
	WUMP_WRITER = 0x80000000U };
typedef struct wump_shared {
	SV *value;
	struct wump_mutation *guard;
	unsigned state, borrows, current_borrows, depth;
	UV generation;
	_Atomic unsigned access;
	const void *writer;
	struct wump_shared *next;
} wump_shared;

struct wump_retired {
	SV *value;
	struct wump_retired *next;
};

struct wump_memory {
	pthread_mutex_t mutex;
	_Atomic uint64_t published[WUMP_MEMORY_FILTER_WORDS];
	wump_shared *buckets[WUMP_MEMORY_BUCKETS];
	struct wump_retired *retired;
	size_t nodes, pins, pending;
	struct wump_parallel_xs *parallel_xs;
};

typedef struct wump_parallel_xs {
	XSUBADDR_t entry;
	struct wump_parallel_xs *next;
} wump_parallel_xs;

void Perl_wump_xs_allow(pTHX_ CV *cv) {
	if (PL_wump_task) croak("Wump: declare XS parallel safety before program execution");
	if (!CvISXSUB(cv)) croak("Wump: parallel XS registration requires an XSUB");
	XSUBADDR_t entry = CvXSUB(cv);
	for (wump_parallel_xs *slot = aTHX->Iwump_memory->parallel_xs; slot; slot = slot->next)
		if (slot->entry == entry) return;
	wump_parallel_xs *slot;
	Newx(slot, 1, wump_parallel_xs);
	slot->entry = entry;
	slot->next = aTHX->Iwump_memory->parallel_xs;
	aTHX->Iwump_memory->parallel_xs = slot;
}

void Perl_wump_xs_check(pTHX_ CV *cv) {
	if (wump_nprocs() <= 1 || CvCONST(cv)) return;
	for (wump_parallel_xs *slot = aTHX->Iwump_memory->parallel_xs; slot; slot = slot->next)
		if (slot->entry == CvXSUB(cv)) return;
	croak("Wump: XS function has not declared parallel safety: %" SVf,
		SVfARG(cv_name(cv, NULL, 0)));
}

bool Perl_wump_parallel(pTHX) {
	return PL_wump_task && wump_nprocs() > 1;
}

U32 Perl_wump_stash_amagic(HV *stash, int operation) {
	dTHX;
	bool parallel = Perl_wump_parallel(aTHX);
	if (parallel) Perl_wump_memory_lock(aTHX);
	U32 flags = SvFLAGS(stash);
	if (operation) {
		flags = operation > 0 ? flags | SVf_AMAGIC : flags & ~SVf_AMAGIC;
		SvFLAGS(stash) = flags;
	}
	if (parallel) Perl_wump_memory_unlock(aTHX);
	return operation ? flags : flags & SVf_AMAGIC;
}

bool Perl_wump_stash_amg(pTHX_ HV *stash) {
	struct wump_mutation *guard = Perl_wump_parallel(aTHX) ? Perl_wump_metadata_begin(aTHX) : NULL;
	bool result = HvNAME(stash) && Gv_AMupdate(stash, FALSE);
	if (!result) SvFLAGS(stash) &= ~SVf_AMAGIC;
	Perl_wump_mutation_end(aTHX_ guard);
	return result;
}

struct wump_mutation {
	wump_shared *node;
	SV *value;
	SV *retained;
	const void *actor;
	I32 mark, top;
	bool active;
};

typedef struct wump_borrow {
	wump_shared *node;
	SV *owner;
	UV generation;
	bool active, reading;
} wump_borrow;

static _Thread_local unsigned char wump_root_actor;
static const void *wump_memory_actor(pTHX) {
	struct wump_perl_task *task = PL_wump_task;
	return task ? (const void *)task : (const void *)&wump_root_actor;
}

static size_t wump_memory_bucket(const SV *value) {
	return ((PTR2UV(value) >> 4) * (UV)2654435761U) & (WUMP_MEMORY_BUCKETS - 1);
}

static wump_shared *wump_memory_find(struct wump_memory *memory, const SV *value) {
	for (wump_shared *node = memory->buckets[wump_memory_bucket(value)]; node; node = node->next)
		if (node->value == value) return node;
	return NULL;
}

static UV wump_memory_filter_hash(const SV *value) {
	return (PTR2UV(value) >> 3) * UINT64_C(0x9e3779b97f4a7c15);
}

static void wump_memory_filter_mark(struct wump_memory *memory, const SV *value) {
	UV hash = wump_memory_filter_hash(value);
	atomic_fetch_or_explicit(&memory->published[hash & (WUMP_MEMORY_FILTER_WORDS - 1)],
		UINT64_C(1) << ((hash >> WUMP_MEMORY_FILTER_SHIFT) & 63), memory_order_release);
}

static bool wump_memory_untracked(struct wump_memory *memory, const SV *value) {
	/* Bits only accumulate, including after rollback and address reuse.
	 * A positive result always goes through the authoritative registry.
	 * This only classifies registry membership; implicit shared values and
	 * native class-cache fields still require their own metadata guards. */
	UV hash = wump_memory_filter_hash(value);
	uint64_t word = atomic_load_explicit(
		&memory->published[hash & (WUMP_MEMORY_FILTER_WORDS - 1)], memory_order_acquire);
	return !(word & (UINT64_C(1) << ((hash >> WUMP_MEMORY_FILTER_SHIFT) & 63)));
}

void Perl_wump_memory_lock(pTHX) {
	if (pthread_mutex_lock(&aTHX->Iwump_memory->mutex)) abort();
}

void Perl_wump_memory_unlock(pTHX) {
	if (pthread_mutex_unlock(&aTHX->Iwump_memory->mutex)) abort();
}

void Perl_wump_memory_init(pTHX) {
	if (aTHX->Iwump_memory) return;
	struct wump_memory *memory = calloc(1, sizeof(*memory));
	if (!memory) croak("Wump: cannot allocate reclamation domain");
	for (size_t i = 0; i < WUMP_MEMORY_FILTER_WORDS; i++)
		atomic_init(&memory->published[i], 0);
	pthread_mutexattr_t attr;
	int result = pthread_mutexattr_init(&attr);
	if (!result) {
		result = pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
		if (!result) result = pthread_mutex_init(&memory->mutex, &attr);
		pthread_mutexattr_destroy(&attr);
	}
	if (result) { free(memory); croak("Wump: cannot initialize reclamation domain"); }
	aTHX->Iwump_memory = memory;
}

void Perl_wump_memory_mark(pTHX_ SV *value, unsigned state) {
	struct wump_memory *memory = aTHX->Iwump_memory;
	Perl_wump_memory_lock(aTHX);
	/* Announce the address before installing metadata. Publication completes
	 * before a value escapes to another act, so its acquire probe cannot
	 * mistake a registered value for an untracked one. Never clear this bit. */
	wump_memory_filter_mark(memory, value);
	wump_shared *node = wump_memory_find(memory, value);
	if (!node && !state) {
		Perl_wump_memory_unlock(aTHX);
		return;
	}
	if (!node) {
		node = calloc(1, sizeof(*node));
		if (!node) {
			Perl_wump_memory_unlock(aTHX);
			croak("Wump: cannot allocate publication metadata");
		}
		node->value = value;
		atomic_init(&node->access, 0);
		size_t bucket = wump_memory_bucket(value);
		node->next = memory->buckets[bucket];
		memory->buckets[bucket] = node;
		memory->nodes++;
	}
	node->state = state;
	Perl_wump_memory_unlock(aTHX);
}

int Perl_wump_memory_shared(pTHX_ const SV *value) {
	if (!aTHX->Iwump_memory) return -1;
	if (wump_memory_untracked(aTHX->Iwump_memory, value)) return -1;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	int result = node && node->state ? node->state == 2 : -1;
	Perl_wump_memory_unlock(aTHX);
	return result;
}

#if defined(PERL_PRESERVE_IVUV) && !defined(PERL_RC_STACK)
static bool wump_numeric_source(pTHX_ SV *value) {
	wump_shared *node = wump_memory_untracked(aTHX->Iwump_memory, value)
		? NULL : wump_memory_find(aTHX->Iwump_memory, value);
	/* Writers keep their logical claim while outside the mutex. Check it
	 * before looking at the flags or the body they might be changing. */
	if (node && ((atomic_load_explicit(&node->access, memory_order_acquire) & WUMP_WRITER)
		|| node->state == 1)) return FALSE;
	if (!SvIOK(value) || SvIsUV(value) || SvROK(value) || SvOBJECT(value)
		|| SvVALID(value) || SvGMAGICAL(value) || SvTYPE(value) > SVt_PVMG
		|| SvTYPE(value) == SVt_INVLIST) return FALSE;
	if (SvTYPE(value) == SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
			if (!Perl_wump_publish_magic(mg)) return FALSE;
	}
	return TRUE;
}
#endif

bool Perl_wump_numeric_enter(pTHX_ SV *target) {
#if defined(PERL_PRESERVE_IVUV) && !defined(PERL_RC_STACK)
	struct wump_perl_task *task = PL_wump_task;
	if (!task || !target || !aTHX->Iwump_memory || !PL_curstackinfo
		|| PL_phase == PERL_PHASE_DESTRUCT || TAINT_get
		|| (PL_signals & PERL_SIGNALS_UNSAFE_FLAG)) return FALSE;
	if (PL_op->op_type != OP_ADD && PL_op->op_type != OP_MODULO) return FALSE;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_untracked(aTHX->Iwump_memory, target)
		? NULL : wump_memory_find(aTHX->Iwump_memory, target);
	/* A private, bodyless IV needs no allocation, magic or COW handling.
	 * Published targets retain the general mutation and unwind protocol. */
	if ((node && (node->state || atomic_load_explicit(&node->access, memory_order_acquire)))
		|| SvTYPE(target) != SVt_IV || SvOBJECT(target)
		|| (SvFLAGS(target) & (SVf_THINKFIRST | SVf_IVisUV))) goto fallback;
	SV *left = PL_stack_sp[-1], *right = PL_stack_sp[0];
	if (!left || !right || !wump_numeric_source(aTHX_ left)
		|| !wump_numeric_source(aTHX_ right)) goto fallback;
	IV lhs = SvIVX(left), rhs = SvIVX(right);
	if (lhs < 0 || rhs < 0) goto fallback;
	if (PL_op->op_type == OP_ADD) {
		if (lhs > IV_MAX / 2 || rhs > IV_MAX / 2) goto fallback;
	} else if (!rhs) goto fallback;
	/* These exact native branches only read cached IVs and store an IV.
	 * They cannot allocate, throw, run get/set magic or decrement stack
	 * references (RC_STACK is excluded). No callback or safepoint occurs
	 * before leave. Holding the recursive metadata mutex closes publication
	 * races without snapshots, heap guards or save-stack records. */
	task->critical++;
	return TRUE;
fallback:
	Perl_wump_memory_unlock(aTHX);
#else
	PERL_UNUSED_ARG(target);
#endif
	return FALSE;
}

void Perl_wump_numeric_leave(pTHX) {
	assert(PL_wump_task && PL_wump_task->critical);
	PL_wump_task->critical--;
	Perl_wump_memory_unlock(aTHX);
}

void Perl_wump_memory_check(pTHX_ const SV *value) {
	if (!aTHX->Iwump_memory) return;
	if (wump_memory_untracked(aTHX->Iwump_memory, value)) return;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	bool busy = node && (atomic_load_explicit(&node->access, memory_order_acquire) & WUMP_WRITER)
		&& node->writer != wump_memory_actor(aTHX);
	Perl_wump_memory_unlock(aTHX);
	if (busy) croak("Wump: publication overlaps mutation of a shared value");
}

bool Perl_wump_read_try_begin(pTHX_ const SV *value, struct wump_shared **claim) {
	*claim = NULL;
	if (!value || !PL_wump_task || !aTHX->Iwump_memory || PL_phase == PERL_PHASE_DESTRUCT) return TRUE;
	if (wump_memory_untracked(aTHX->Iwump_memory, value)) return TRUE;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	if (!node || node->state != 2) {
		Perl_wump_memory_unlock(aTHX);
		return TRUE;
	}
	unsigned access = atomic_load_explicit(&node->access, memory_order_acquire);
	if (access & WUMP_WRITER) {
		bool own = node->writer == wump_memory_actor(aTHX);
		Perl_wump_memory_unlock(aTHX);
		return own;
	}
	atomic_fetch_add_explicit(&node->access, 1, memory_order_acquire);
	Perl_wump_memory_unlock(aTHX);
	*claim = node;
	return TRUE;
}

struct wump_shared *Perl_wump_read_begin(pTHX_ const SV *value) {
	struct wump_shared *claim;
	if (!Perl_wump_read_try_begin(aTHX_ value, &claim))
		croak("Wump: read overlaps mutation of a shared value");
	return claim;
}

void Perl_wump_read_end(pTHX_ struct wump_shared *claim) {
	if (!claim) return;
	Perl_wump_memory_lock(aTHX);
	unsigned before = atomic_fetch_sub_explicit(&claim->access, 1, memory_order_release);
	assert(before && !(before & WUMP_WRITER));
	Perl_wump_memory_unlock(aTHX);
}

void Perl_wump_memory_forget(pTHX_ SV *value) {
	struct wump_memory *memory = aTHX->Iwump_memory;
	if (!memory) return;
	if (wump_memory_untracked(memory, value)) return;
	Perl_wump_memory_lock(aTHX);
	wump_shared **link = &memory->buckets[wump_memory_bucket(value)];
	while (*link && (*link)->value != value) link = &(*link)->next;
	if (*link) {
		wump_shared *node = *link;
		assert(!node->borrows && !atomic_load_explicit(&node->access, memory_order_relaxed));
		*link = node->next;
		memory->nodes--;
		free(node);
	}
	Perl_wump_memory_unlock(aTHX);
}

static void wump_memory_requeue(pTHX_ void *arg) {
	struct wump_retired **remaining = arg;
	Perl_wump_memory_lock(aTHX);
	while (*remaining) {
		struct wump_retired *record = *remaining;
		*remaining = record->next;
		record->next = aTHX->Iwump_memory->retired;
		aTHX->Iwump_memory->retired = record;
		aTHX->Iwump_memory->pending++;
	}
	Perl_wump_memory_unlock(aTHX);
}

static void wump_memory_drain(pTHX_ struct wump_retired *retired) {
	if (!retired) return;
	ENTER;
	SAVEDESTRUCTOR_X(wump_memory_requeue, &retired);
	while (retired) {
		struct wump_retired *record = retired;
		SV *value = record->value;
		retired = record->next;
		free(record);
		/* Destructors and key releases run with no metadata mutex held. */
		SvREFCNT_dec(value);
	}
	LEAVE;
}

void Perl_wump_memory_collect(pTHX) {
	struct wump_memory *memory = aTHX->Iwump_memory;
	if (!memory) return;
	Perl_wump_memory_lock(aTHX);
	struct wump_retired *retired = NULL;
	if (!memory->pins) {
		retired = memory->retired;
		memory->retired = NULL;
		memory->pending = 0;
	}
	Perl_wump_memory_unlock(aTHX);
	wump_memory_drain(aTHX_ retired);
}

struct wump_retired *Perl_wump_retire_prepare(pTHX_ SV *value) {
	struct wump_retired *retired = malloc(sizeof(*retired));
	if (!retired) croak("Wump: cannot allocate retirement record");
	retired->value = SvREFCNT_inc(value);
	retired->next = NULL;
	return retired;
}

void Perl_wump_retire_commit(pTHX_ struct wump_retired *retired) {
	struct wump_memory *memory = aTHX->Iwump_memory;
	Perl_wump_memory_lock(aTHX);
	bool defer = memory->pins != 0;
	if (defer) {
		retired->next = memory->retired;
		memory->retired = retired;
		memory->pending++;
	}
	Perl_wump_memory_unlock(aTHX);
	if (!defer) wump_memory_drain(aTHX_ retired);
}

void Perl_wump_memory_stats(pTHX_ size_t *pins, size_t *retired, size_t *nodes) {
	Perl_wump_memory_lock(aTHX);
	*pins = aTHX->Iwump_memory->pins;
	*retired = aTHX->Iwump_memory->pending;
	*nodes = aTHX->Iwump_memory->nodes;
	Perl_wump_memory_unlock(aTHX);
}

void Perl_wump_memory_destroy(pTHX) {
	struct wump_memory *memory = aTHX->Iwump_memory;
	if (!memory) return;
	Perl_wump_memory_collect(aTHX);
	assert(!memory->pins && !memory->retired);
	while (memory->parallel_xs) {
		wump_parallel_xs *slot = memory->parallel_xs;
		memory->parallel_xs = slot->next;
		Safefree(slot);
	}
	for (size_t i = 0; i < WUMP_MEMORY_BUCKETS; i++) {
		wump_shared *node = memory->buckets[i];
		while (node) {
			wump_shared *next = node->next;
			assert(!node->borrows && !atomic_load_explicit(&node->access, memory_order_relaxed));
			free(node);
			node = next;
		}
	}
	aTHX->Iwump_memory = NULL;
	if (pthread_mutex_destroy(&memory->mutex)) abort();
	free(memory);
}

void Perl_wump_memory_clone_check(pTHX) {
	if (!aTHX->Iwump_memory) return;
	Perl_wump_memory_lock(aTHX);
	bool busy = aTHX->Iwump_memory->pins != 0;
	for (size_t i = 0; !busy && i < WUMP_MEMORY_BUCKETS; i++)
		for (wump_shared *node = aTHX->Iwump_memory->buckets[i]; node; node = node->next)
			if (atomic_load_explicit(&node->access, memory_order_acquire)) { busy = TRUE; break; }
	Perl_wump_memory_unlock(aTHX);
	if (busy) croak("Wump: cannot clone an interpreter with active borrows or mutations");
}

static void wump_mutation_release(pTHX_ struct wump_mutation *guard) {
	if (!guard || !guard->active) return;
	guard->active = FALSE;
	if (!guard->node) {
		if (PL_wump_task) {
			assert(PL_wump_task->critical);
			PL_wump_task->critical--;
		}
		Perl_wump_memory_unlock(aTHX);
		return;
	}
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = guard->node;
	assert(node->writer == guard->actor && node->depth);
	if (!--node->depth) {
		node->writer = NULL;
		node->guard = NULL;
		atomic_store_explicit(&node->access, 0, memory_order_release);
	}
	Perl_wump_memory_unlock(aTHX);
	SvREFCNT_dec(guard->retained);
	SvREFCNT_dec(guard->value);
}

static void wump_mutation_unwind(pTHX_ void *arg) {
	struct wump_mutation *guard = arg;
	wump_mutation_release(aTHX_ guard);
	free(guard);
}

struct wump_mutation *Perl_wump_metadata_begin(pTHX) {
	if (!aTHX->Iwump_memory || !PL_curstackinfo || PL_phase == PERL_PHASE_DESTRUCT) return NULL;
	SSCHECK(3);
	struct wump_mutation *guard = calloc(1, sizeof(*guard));
	if (!guard) croak("Wump: cannot allocate metadata guard");
	guard->mark = PL_savestack_ix;
	SAVEDESTRUCTOR_X(wump_mutation_unwind, guard);
	guard->top = PL_savestack_ix;
	Perl_wump_memory_lock(aTHX);
	guard->active = TRUE;
	if (PL_wump_task) PL_wump_task->critical++;
	return guard;
}

static void wump_schedule_check(pTHX) {
	if (PL_wump_task && (PL_wump_task->critical || Perl_wump_publish_active(aTHX)))
		croak("Wump: scheduling inside a native metadata operation is not supported");
}

static struct wump_mutation *wump_mutation_begin(pTHX_ SV *value, bool *busy) {
	if (busy) *busy = FALSE;
	if (!value || !PL_wump_task || !aTHX->Iwump_memory || PL_phase == PERL_PHASE_DESTRUCT) return NULL;
	if (wump_memory_untracked(aTHX->Iwump_memory, value)) return NULL;
	/* Interning grows strtab under its own mutex. It is not a user graph;
	 * do not introduce the reverse keys-mutex -> metadata-mutex order. */
	if (value == (SV *)PL_strtab) return NULL;
	if (Perl_wump_overlay_active(aTHX_ value)) return NULL;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	bool shared = node && node->state == 2;
	Perl_wump_memory_unlock(aTHX);
	if (!shared || !SvREFCNT(value)) return NULL;
	/* Reserve save-stack capacity before taking the claim, so an allocation
	 * exception cannot strand a writer without its unwind callback. */
	SSCHECK(3);
	struct wump_mutation *guard = malloc(sizeof(*guard));
	if (!guard) croak("Wump: cannot allocate mutation guard");
	const void *actor = wump_memory_actor(aTHX);
	Perl_wump_memory_lock(aTHX);
	unsigned access = atomic_load_explicit(&node->access, memory_order_acquire);
	if (access && (!(access & WUMP_WRITER) || node->writer != actor)) {
		Perl_wump_memory_unlock(aTHX);
		free(guard);
		if (busy) { *busy = TRUE; return NULL; }
		croak("Wump: concurrent mutation of a shared value");
	}
	bool detach = !access && node->current_borrows;
	atomic_store_explicit(&node->access, WUMP_WRITER, memory_order_release);
	node->writer = actor;
	node->depth++;
	guard->node = node;
	guard->retained = NULL;
	guard->actor = actor;
	guard->value = SvREFCNT_inc(value);
	guard->active = TRUE;
	if (!access) node->guard = guard;
	Perl_wump_memory_unlock(aTHX);
	guard->mark = PL_savestack_ix;
	SAVEDESTRUCTOR_X(wump_mutation_unwind, guard);
	guard->top = PL_savestack_ix;
	if (detach && !SvREADONLY(value)) {
		if (SvTYPE(value) == SVt_PVAV) Perl_wump_av_detach(aTHX_ (AV *)value);
		else if (SvTYPE(value) == SVt_PVHV) Perl_wump_hv_detach(aTHX_ (HV *)value);
		else Perl_wump_sv_detach(aTHX_ value);
	}
	return guard;
}

struct wump_mutation *Perl_wump_mutation_begin(pTHX_ SV *value) {
	return wump_mutation_begin(aTHX_ value, NULL);
}

struct wump_mutation *Perl_wump_mutation_try_begin(pTHX_ SV *value, bool *busy) {
	assert(busy);
	return wump_mutation_begin(aTHX_ value, busy);
}

void Perl_wump_mutation_keep(pTHX_ SV *value, SV *retained) {
	/* The outer guard is the first SAVEDESTRUCTOR record for this mutation.
	 * Keep the source argument's old storage alive until the C API returns,
	 * even if the last long-lived borrower leaves during preparation. */
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	assert(node && node->writer == wump_memory_actor(aTHX) && node->depth);
	struct wump_mutation *guard = node->guard;
	assert(guard && !guard->retained);
	guard->retained = SvREFCNT_inc(retained);
	Perl_wump_memory_unlock(aTHX);
}

void Perl_wump_storage_changed(pTHX_ SV *value) {
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	assert(node && node->writer == wump_memory_actor(aTHX));
	node->generation++;
	node->current_borrows = 0;
	Perl_wump_memory_unlock(aTHX);
}

void Perl_wump_mutation_end(pTHX_ struct wump_mutation *guard) {
	if (!guard) return;
	I32 mark = guard->mark, top = guard->top;
	wump_mutation_release(aTHX_ guard);
	/* Preserve saves deliberately left for the caller by the core API. An
	 * inactive guard underneath them is freed on ordinary scope unwind. */
	if (PL_savestack_ix == top) LEAVE_SCOPE(mark);
}

const char *Perl_wump_mutation_pointer(pTHX_ struct wump_mutation *guard, const char *pointer) {
	if (!guard) return pointer;
	SV *old = guard->node->guard->retained;
	if (!old || SvTYPE(old) != SVt_PVMG || !SvPVX_const(old)) return pointer;
	UV offset = PTR2UV(pointer) - PTR2UV(SvPVX_const(old));
	return offset <= SvCUR(old) ? SvPVX_const(guard->value) + offset : pointer;
}

static SV *wump_borrow_release(pTHX_ wump_borrow *borrow) {
	if (!borrow) return NULL;
	if (borrow->active) {
		borrow->active = FALSE;
		Perl_wump_memory_lock(aTHX);
		if (borrow->reading)
			atomic_fetch_sub_explicit(&borrow->node->access, 1, memory_order_release);
		assert(borrow->node->borrows && aTHX->Iwump_memory->pins);
		borrow->node->borrows--;
		if (borrow->generation == borrow->node->generation) {
			assert(borrow->node->current_borrows);
			borrow->node->current_borrows--;
		}
		aTHX->Iwump_memory->pins--;
		Perl_wump_memory_unlock(aTHX);
		return borrow->owner;
	}
	return NULL;
}

static void wump_borrow_cancel(pTHX_ wump_borrow *borrow) {
	SV *owner = wump_borrow_release(aTHX_ borrow);
	SvREFCNT_dec(owner);
	Perl_wump_memory_collect(aTHX);
}

static int wump_borrow_free(pTHX_ SV *token, MAGIC *mg) {
	PERL_UNUSED_ARG(token);
	wump_borrow *borrow = (wump_borrow *)mg->mg_ptr;
	mg->mg_ptr = NULL;
	SV *owner = wump_borrow_release(aTHX_ borrow);
	free(borrow);
	SvREFCNT_dec(owner);
	Perl_wump_memory_collect(aTHX);
	return 0;
}

static const MGVTBL wump_borrow_vtbl = { .svt_free = wump_borrow_free };

/* Pin creation has no save-stack effects on the cached-PV path. In
 * particular, it is valid while a caller assembles a localization record. */
static wump_borrow *wump_borrow_new(pTHX) {
	SV *token = sv_2mortal(newSV_type(SVt_PVMG));
	MAGIC *mg = sv_magicext(token, NULL, PERL_MAGIC_ext, &wump_borrow_vtbl, NULL, 0);
	wump_borrow *borrow = calloc(1, sizeof(*borrow));
	if (!borrow) croak("Wump: cannot allocate lifetime pin");
	mg->mg_ptr = (char *)borrow;
	mg->mg_len = -1;
	return borrow;
}

static wump_borrow *wump_borrow_start(pTHX_ SV *value) {
	if (!value || !aTHX->Iwump_memory || !PL_curstackinfo || PL_phase == PERL_PHASE_DESTRUCT)
		return NULL;
	if (wump_memory_untracked(aTHX->Iwump_memory, value)) return NULL;
	Perl_wump_memory_lock(aTHX);
	wump_shared *node = wump_memory_find(aTHX->Iwump_memory, value);
	bool shared = node && node->state == 2;
	Perl_wump_memory_unlock(aTHX);
	if (!shared) return NULL;
	wump_borrow *borrow = wump_borrow_new(aTHX);
	Perl_wump_memory_lock(aTHX);
	unsigned access = atomic_load_explicit(&node->access, memory_order_acquire);
	if (access & WUMP_WRITER) {
		if (node->writer != wump_memory_actor(aTHX)) {
			Perl_wump_memory_unlock(aTHX);
			croak("Wump: read overlaps mutation of a shared value");
		}
	} else {
		atomic_fetch_add_explicit(&node->access, 1, memory_order_acquire);
		borrow->reading = TRUE;
	}
	borrow->node = node;
	borrow->owner = SvREFCNT_inc(value);
	borrow->generation = node->generation;
	borrow->active = TRUE;
	node->borrows++;
	node->current_borrows++;
	aTHX->Iwump_memory->pins++;
	Perl_wump_memory_unlock(aTHX);
	return borrow;
}

static void wump_borrow_read_end(pTHX_ wump_borrow *borrow) {
	if (!borrow || !borrow->reading) return;
	Perl_wump_memory_lock(aTHX);
	atomic_fetch_sub_explicit(&borrow->node->access, 1, memory_order_release);
	borrow->reading = FALSE;
	Perl_wump_memory_unlock(aTHX);
}

struct wump_borrow *Perl_wump_capture_begin(pTHX_ const SV *value) {
	return PL_wump_task ? wump_borrow_start(aTHX_ (SV *)value) : NULL;
}

void Perl_wump_capture_end(pTHX_ struct wump_borrow *capture) {
	SV *owner = wump_borrow_release(aTHX_ capture);
	SvREFCNT_dec(owner);
	/* The now-inactive mortal token collects later. Do not run destructors
	 * or add save entries while a core caller assembles a localization record. */
}

SV *Perl_wump_xs_scalar(pTHX_ SV *value, const char *operation) {
	struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ value);
	bool plain = SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
		&& !SvROK(value) && !SvOBJECT(value) && !SvVALID(value);
	if (plain && SvTYPE(value) == SVt_PVMG) {
		for (MAGIC *magic = SvMAGIC(value); magic; magic = magic->mg_moremagic)
			if (!Perl_wump_publish_magic(magic)) { plain = FALSE; break; }
	}
	if (!plain) {
		Perl_wump_capture_end(aTHX_ capture);
		croak("Wump: %s requires a plain scalar", operation);
	}
	/* Copy bytes and caches without COW writes to the source. Native byte
	 * conversion can now downgrade, coerce or throw on this private head. */
	SV *copy = sv_2mortal(newSV_type(SVt_PVNV));
	U32 flags = SvFLAGS(value);
	if (SvPOKp(value))
		sv_setpvn(copy, SvPVX_const(value) ? SvPVX_const(value) : "", SvCUR(value));
	if (SvIOKp(value)) {
		if (SvIsUV(value)) SvUV_set(copy, SvUVX(value));
		else SvIV_set(copy, SvIVX(value));
	}
	if (SvNOKp(value)) SvNV_set(copy, SvNVX(value));
	const U32 cache = SVf_IOK | SVp_IOK | SVf_NOK | SVp_NOK
		| SVf_POK | SVp_POK | SVf_IVisUV | SVf_UTF8;
	SvFLAGS(copy) = (SvFLAGS(copy) & ~cache) | (flags & cache);
	Perl_wump_capture_end(aTHX_ capture);
	return copy;
}

static bool wump_borrow_plain(pTHX_ const SV *value) {
	if (SvTYPE(value) != SVt_PVMG || SvROK(value) || SvOBJECT(value) || SvVALID(value)) return FALSE;
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
		if (!Perl_wump_publish_magic(mg)) return FALSE;
	return TRUE;
}

char *Perl_wump_pv(pTHX_ SV *value, STRLEN *length, U32 flags) {
	return Perl_wump_pv_encoded(aTHX_ value, length, flags, 0, FALSE);
}

char *Perl_wump_pv_encoded(pTHX_ SV *value, STRLEN *length, U32 flags, int encoding, bool or_null) {
	char *(*convert)(pTHX_ SV *, STRLEN *const, const U32) = encoding == 1
		? Perl_sv_2pvbyte_flags : encoding == 2 ? Perl_sv_2pvutf8_flags : Perl_sv_2pv_flags;
	PL_SvPVtype type = encoding == 1 ? SvPVbyte_type_ : encoding == 2 ? SvPVutf8_type_ : SvPVnormal_type_;
	/* Ordinary interpreter execution has no migrating C frame to protect.
	 * Preserve its upstream cached-PV fast path, including build tools. */
	if (!PL_wump_task)
		return Perl_SvPV_helper(aTHX_ value, length, flags, type,
			convert, or_null, flags & (SV_CONST_RETURN | SV_MUTABLE_RETURN));
	if (flags & SV_MUTABLE_RETURN) return convert(aTHX_ value, length, flags);
	wump_borrow *borrow = wump_borrow_start(aTHX_ value);
	if (!borrow) return Perl_SvPV_helper(aTHX_ value, length, flags, type,
		convert, or_null, flags & SV_CONST_RETURN);
	if (!wump_borrow_plain(aTHX_ value)) {
		wump_borrow_cancel(aTHX_ borrow);
		return Perl_SvPV_helper(aTHX_ value, length, flags, type, convert, or_null, flags & SV_CONST_RETURN);
	}
	if (or_null && !SvOK(value)) {
		if (length) *length = 0;
		wump_borrow_read_end(aTHX_ borrow);
		return NULL;
	}
	bool compatible = !encoding || (SvPOK(value) && (encoding == 2) == !!SvUTF8(value));
	if (SvPOKp(value) && compatible && borrow->reading) {
		char *result = (char *)SvPVX_const(value);
		if (length) *length = SvCUR(value);
		wump_borrow_read_end(aTHX_ borrow);
		return result;
	}
	SV *copy = sv_2mortal(Perl_wump_scalar_snapshot(aTHX_ value));
	wump_borrow_read_end(aTHX_ borrow);
	return Perl_wump_read_snapshot_pv(aTHX_ value, copy, length, flags, encoding);
}

/* A raw slot/HE cannot escape the container's read claim. Retain the actual
 * element head in a private mortal RV before releasing that claim. Making the
 * shared head itself mortal (or newRV_noinc) would change its TEMP flag. */
static SV *wump_load_keep(pTHX_ SV *holder, SV *value) {
	if (!value) return &PL_sv_undef;
	SvRV_set(holder, SvREFCNT_inc(value));
	SvROK_on(holder);
	return value;
}

SV *Perl_wump_load_rv(pTHX_ SV *value, svtype type, bool *handled) {
	*handled = FALSE;
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	wump_borrow *source = wump_borrow_start(aTHX_ value);
	if (!source) return NULL;
	bool plain = SvTYPE(value) <= SVt_PVMG && SvROK(value)
		&& !SvWEAKREF(value) && !SvOBJECT(value) && !SvVALID(value);
	if (plain && SvTYPE(value) == SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
			if (!Perl_wump_publish_magic(mg) && mg->mg_type != PERL_MAGIC_backref) plain = FALSE;
	}
	SV *result = plain ? wump_load_keep(aTHX_ holder, SvRV(value)) : NULL;
	/* Keep the referent independently of its source before releasing the
	 * source claim. Neither claim spans index/key evaluation or Perl magic. */
	wump_borrow_cancel(aTHX_ source);
	if (!result) return NULL;
	wump_borrow *target = wump_borrow_start(aTHX_ result);
	/* SVt_PV denotes rv2sv's scalar family, including another reference or
	 * an lvalue delegate. Keep the original head so writes and magic still
	 * operate on that alias; capturing its current contents would not do. */
	*handled = target && !SvOBJECT(result)
		&& ((type == SVt_PV && SvTYPE(result) < SVt_PVAV)
			|| ((type == SVt_PVAV || type == SVt_PVHV) && SvTYPE(result) == type));
	wump_borrow_cancel(aTHX_ target);
	if (!*handled) {
		/* Ineligible magic/overload/type paths must not gain a hidden strong
		 * reference which could change destructor timing or weak semantics. */
		sv_set_undef(holder);
		return NULL;
	}
	return result;
}

SV *Perl_wump_load_av(pTHX_ AV *value, SSize_t index, bool *handled) {
	*handled = FALSE;
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	wump_borrow *borrow = wump_borrow_start(aTHX_ (SV *)value);
	if (!borrow) return NULL;
	bool plain = SvTYPE(value) == SVt_PVAV && AvREAL(value)
		&& !Perl_wump_overlay_active(aTHX_ (SV *)value);
	if (plain) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if (!Perl_wump_publish_magic(mg) && !Perl_wump_element_magic(mg)
				&& mg->mg_type != PERL_MAGIC_backref) plain = FALSE;
		}
	}
	SV *result = NULL;
	if (plain) {
		if (index < 0) index += AvFILLp(value) + 1;
		result = wump_load_keep(aTHX_ holder,
			index >= 0 && index <= AvFILLp(value) ? AvARRAY(value)[index] : NULL);
		*handled = TRUE;
	}
	wump_borrow_cancel(aTHX_ borrow);
	return result;
}

SV *Perl_wump_load_hv(pTHX_ HV *value, SV *key, bool *handled) {
	*handled = FALSE;
	/* Only cached ordinary string keys belong to this callback-free path.
	 * Copy under the key's claim so hash UTF-8 canonicalization cannot change
	 * shared caches. Numeric, tied and overloaded keys keep the core path. */
	wump_borrow *key_borrow = wump_borrow_start(aTHX_ key);
	bool plain = SvTYPE(key) <= SVt_PVMG && !SvROK(key) && !SvOBJECT(key)
		&& !SvVALID(key) && SvPOK(key);
	if (plain && SvTYPE(key) == SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(key); mg; mg = mg->mg_moremagic)
			if (!Perl_wump_publish_magic(mg)) plain = FALSE;
	}
	if (!plain) {
		wump_borrow_cancel(aTHX_ key_borrow);
		return NULL;
	}
	SV *copy = sv_2mortal(newSVpvn_flags(SvPVX_const(key), SvCUR(key),
		SvUTF8(key) ? SVf_UTF8 : 0));
	wump_borrow_cancel(aTHX_ key_borrow);
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	wump_borrow *borrow = wump_borrow_start(aTHX_ (SV *)value);
	if (!borrow) return NULL;
	SV *result = NULL;
	if (Perl_wump_hv_readable(aTHX_ value)) {
		/* A disallowed restricted-hash key croaks through a Perl die hook.
		 * Probe without that callback, then let the native path diagnose a
		 * miss after this claim is gone. Existing entries still get pinned. */
		bool restricted = SvREADONLY(value);
		HE *entry = (HE *)hv_common(value, NULL, SvPVX_const(copy), SvCUR(copy),
			SvUTF8(copy) ? HVhek_UTF8 : 0, restricted ? HV_FETCH_ISEXISTS : 0, NULL, 0);
		if (entry || !restricted) {
			result = wump_load_keep(aTHX_ holder, entry ? HeVAL(entry) : NULL);
			*handled = TRUE;
		}
	}
	wump_borrow_cancel(aTHX_ borrow);
	return result;
}

SV **Perl_wump_borrow_av(pTHX_ AV *value, SSize_t index) {
	wump_borrow *borrow = wump_borrow_start(aTHX_ (SV *)value);
	if (!borrow) croak("Wump: array borrowing requires a published array");
	if (!borrow->reading) croak("Wump: cannot borrow array storage inside its mutation");
	if (SvTYPE(value) != SVt_PVAV || !AvREAL(value)) {
		wump_borrow_read_end(aTHX_ borrow);
		croak("Wump: array borrowing requires ordinary real storage");
	}
	for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
		if (!Perl_wump_publish_magic(mg)) {
			wump_borrow_read_end(aTHX_ borrow);
			croak("Wump: magical array borrowing is not supported");
		}
	}
	if (index < 0) index += AvFILLp(value) + 1;
	SV **result = index >= 0 && index <= AvFILLp(value) ? &AvARRAY(value)[index] : NULL;
	wump_borrow_read_end(aTHX_ borrow);
	if (!result) wump_borrow_cancel(aTHX_ borrow);
	return result;
}

HE *Perl_wump_borrow_hv(pTHX_ HV *value, const char *key, STRLEN length, U32 hash) {
	wump_borrow *borrow = wump_borrow_start(aTHX_ (SV *)value);
	if (!borrow) croak("Wump: hash borrowing requires a published hash");
	if (!borrow->reading) croak("Wump: cannot borrow hash storage inside its mutation");
	if (!Perl_wump_hv_readable(aTHX_ value)) {
		wump_borrow_read_end(aTHX_ borrow);
		croak("Wump: magical hash borrowing is not supported");
	}
	HE *result = (HE *)hv_common(value, NULL, key, length, 0, 0, NULL, hash);
	wump_borrow_read_end(aTHX_ borrow);
	if (!result) wump_borrow_cancel(aTHX_ borrow);
	return result;
}
