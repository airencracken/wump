#ifndef WUMP_TEST_BUDGET_H
#define WUMP_TEST_BUDGET_H

#ifndef WUMP_TEST_CASE_TIMEOUT
#define WUMP_TEST_CASE_TIMEOUT 30
#endif

static inline unsigned wump_test_case_timeout(void) {
	unsigned seconds = WUMP_TEST_CASE_TIMEOUT;
#ifdef WUMP_VALGRIND
	if (RUNNING_ON_VALGRIND && seconds < 120) seconds = 120;
#endif
	return seconds;
}

#endif
