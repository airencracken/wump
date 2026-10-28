/* Included by sv.c after arena_set's definition. No Perl callbacks or
 * scheduling occur while manipulating these executor-owned free lists. */
#include <stdatomic.h>
static _Thread_local struct wump_perl_allocator *wump_current_allocator;

__attribute__((noinline)) struct wump_perl_allocator *Perl_wump_allocator_current(pTHX) {
	__asm__ volatile("" ::: "memory");
	struct wump_perl_allocator *pool = wump_current_allocator;
	return pool && pool->interp == aTHX ? pool : NULL;
}

void Perl_wump_allocator_activate(pTHX_ struct wump_perl_allocator *pool) {
	assert(pool == NULL || pool->interp == aTHX);
	__asm__ volatile("" ::: "memory");
	wump_current_allocator = pool;
}

#define WUMP_ALLOCATOR_FIELD(type, name) \
__attribute__((noinline)) type *Perl_wump_allocator_##name(pTHX) { \
	struct wump_perl_allocator *pool = Perl_wump_allocator_current(aTHX); \
	return pool ? &pool->I##name : &aTHX->I##name; \
}
WUMP_ALLOCATOR_FIELD(SV *, sv_root)
WUMP_ALLOCATOR_FIELD(SV *, sv_arenaroot)
WUMP_ALLOCATOR_FIELD(IV, sv_count)
WUMP_ALLOCATOR_FIELD(void *, body_arenas)
#undef WUMP_ALLOCATOR_FIELD

__attribute__((noinline)) void *(*Perl_wump_allocator_body_roots(pTHX))[PERL_ARENA_ROOTS_SIZE] {
	struct wump_perl_allocator *pool = Perl_wump_allocator_current(aTHX);
	return pool ? &pool->Ibody_roots : &aTHX->Ibody_roots;
}

void Perl_wump_allocator_merge(pTHX_ struct wump_perl_allocator *pool) {
	assert(pool && pool->interp == aTHX && Perl_wump_allocator_current(aTHX) == NULL);
	/* A value can outlive its executor or be freed on another executor.
	 * Keep arenas intact, join caches, and add signed allocation deltas.
	 * Only the interpreter's final teardown releases arena mappings. */
	if (pool->Isv_root) {
		SV *tail = pool->Isv_root;
		while (SvARENA_CHAIN(tail)) tail = MUTABLE_SV(SvARENA_CHAIN(tail));
		SvARENA_CHAIN_SET(tail, aTHX->Isv_root);
		aTHX->Isv_root = pool->Isv_root;
		pool->Isv_root = NULL;
	}
	if (pool->Isv_arenaroot) {
		SV *tail = pool->Isv_arenaroot;
		while (SvANY(tail)) tail = MUTABLE_SV(SvANY(tail));
		SvANY(tail) = aTHX->Isv_arenaroot;
		aTHX->Isv_arenaroot = pool->Isv_arenaroot;
		pool->Isv_arenaroot = NULL;
	}
	for (unsigned i = 0; i < PERL_ARENA_ROOTS_SIZE; i++) {
		if (!pool->Ibody_roots[i]) continue;
		void **tail = (void **)pool->Ibody_roots[i];
		while (*tail) tail = (void **)*tail;
		*tail = aTHX->Ibody_roots[i];
		aTHX->Ibody_roots[i] = pool->Ibody_roots[i];
		pool->Ibody_roots[i] = NULL;
	}
	if (pool->Ibody_arenas) {
		struct arena_set *tail = (struct arena_set *)pool->Ibody_arenas;
		while (tail->next) tail = tail->next;
		tail->next = (struct arena_set *)aTHX->Ibody_arenas;
		aTHX->Ibody_arenas = pool->Ibody_arenas;
		pool->Ibody_arenas = NULL;
	}
	aTHX->Isv_count += pool->Isv_count;
	pool->Isv_count = 0;
}
