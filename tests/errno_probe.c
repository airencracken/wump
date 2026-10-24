#include <errno.h>

/* Separate translation unit: C code must not retain TLS pointers across
 * a yield when tasks may migrate to another OS thread. */
void wump_test_set_errno(int value) {
	errno = value;
}

int wump_test_get_errno(void) {
	return errno;
}
