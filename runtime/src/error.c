#include <errno.h>

/* The compiler must fetch libc's thread-local errno address in this call,
 * never carry it across a yielding read/write retry loop in the caller.
 * The memory barrier also prevents interprocedural purity assumptions. */
__attribute__((noinline)) int wump_errno(void) {
	__asm__ volatile("" ::: "memory");
	return errno;
}

__attribute__((noinline)) void wump_set_errno(int error) {
	__asm__ volatile("" ::: "memory");
	errno = error;
}
