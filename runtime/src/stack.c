#define _GNU_SOURCE
#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "internal.h"

void *wump_ctx_init(void *stack_top, void (*fn)(void *), void *arg) {
	/* On entry to the trampoline rsp is 16-byte aligned, so its call
	 * instruction gives the C entry point the SysV-required alignment. */
	uintptr_t top = (uintptr_t)stack_top & ~(uintptr_t)15;
	uint64_t *frame = (uint64_t *)(top - 64);
	memset(frame, 0, 64);
	__asm__ volatile("stmxcsr %0" : "=m"(*(uint32_t *)frame));
	__asm__ volatile("fnstcw %0" : "=m"(*(uint16_t *)((char *)frame + 4)));
	frame[3] = (uintptr_t)arg; /* r13 */
	frame[4] = (uintptr_t)fn;  /* r12 */
	frame[7] = (uintptr_t)wump_ctx_trampoline;
	return frame;
}

wump_g *wump_stack_new(size_t stack_size) {
	long page_result = sysconf(_SC_PAGESIZE);
	if (page_result <= 0) {
		errno = EINVAL;
		return NULL;
	}
	size_t page = (size_t)page_result;
	if (stack_size < page || stack_size > SIZE_MAX - sizeof(wump_g) - 2 * page) {
		errno = EINVAL;
		return NULL;
	}
	size_t usable = (stack_size + sizeof(wump_g) + page - 1) / page * page;
	size_t length = page + usable;
	void *map = mmap(NULL, length, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
	if (map == MAP_FAILED) {
		return NULL;
	}
	if (mprotect(map, page, PROT_NONE) != 0) {
		int error = errno;
		munmap(map, length);
		errno = error;
		return NULL;
	}
	uintptr_t top = ((uintptr_t)map + length - sizeof(wump_g)) & ~(uintptr_t)15;
	wump_g *g = (wump_g *)top;
	memset(g, 0, sizeof(*g));
	g->map = map;
	g->map_len = length;
	g->stack_lo = (uint64_t *)((char *)map + page);
	*g->stack_lo = WUMP_STACK_CANARY;
#ifdef WUMP_VALGRIND
	g->valgrind_stack = VALGRIND_STACK_REGISTER(g->stack_lo + 1, g);
#endif
	return g;
}

void wump_stack_free(wump_g *g) {
#ifdef WUMP_VALGRIND
	VALGRIND_STACK_DEREGISTER(g->valgrind_stack);
#endif
#ifdef WUMP_ASAN
	__asan_unpoison_memory_region(g->stack_lo + 1,
		(size_t)((char *)g - (char *)(g->stack_lo + 1)));
#endif
	munmap(g->map, g->map_len);
}
