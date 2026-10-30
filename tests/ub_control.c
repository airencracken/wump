#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wump.h"

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static volatile int result;
static volatile float fraction;
static __attribute__((noinline)) int incompatible(int n) { return n + 1; }

static void control(void *arg) {
	const char *kind = arg;
	wump_yield();
	if (strcmp(kind, "overflow") == 0) {
		volatile int value = INT_MAX;
		result = value + 1;
	} else if (strcmp(kind, "bounds") == 0) {
		volatile int values[2] = {0, 1};
		volatile int index = 2;
		result = values[index];
	} else if (strcmp(kind, "float") == 0) {
		volatile float zero = 0;
		fraction = 1 / zero;
	} else if (strcmp(kind, "conversion") == 0) {
		volatile int value = 256;
		volatile unsigned char truncated = value;
		result = truncated;
	} else if (strcmp(kind, "cfi") == 0) {
		union { int (*integer)(int); void (*callback)(void *); } target;
		target.integer = incompatible;
		target.callback(NULL);
	} else {
		CHECK(strcmp(kind, "clean") == 0);
		result = 19;
	}
}

int main(int argc, char **argv) {
	CHECK(argc <= 2);
	CHECK(wump_run(control, argc == 2 ? argv[1] : "clean", 1) == 0);
	return 0;
}
