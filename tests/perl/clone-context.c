#include "EXTERN.h"
#include "perl.h"
#include <stdio.h>
#include <string.h>

static bool probe, failed;
static PerlInterpreter *candidate;
static unsigned switches;
extern void *__real_malloc(size_t);

void *__wrap_malloc(size_t size) {
	void *memory = __real_malloc(size);
	if (probe && !candidate && size == sizeof(PerlInterpreter) && memory) {
		/* A clone uses malloc, unlike perl_alloc's cleared allocation. */
		memset(memory, 0xa5, size);
		candidate = memory;
	}
	return memory;
}

#ifdef USE_PERL_SWITCH_LOCALE_CONTEXT
extern void __real_Perl_switch_locale_context(pTHX);
void __wrap_Perl_switch_locale_context(pTHX) {
	if (aTHX == candidate) {
		switches++;
		if (S_wump_context_seen(aTHX)) failed = TRUE;
	}
	__real_Perl_switch_locale_context(aTHX);
}
#endif

int main(int argc, char **argv, char **env) {
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *parent = perl_alloc();
	if (!parent) return 1;
	PERL_SET_CONTEXT(parent);
	perl_construct(parent);
	char program[] = "clone-context", option[] = "-e", code[] = "0";
	char *args[] = {program, option, code, NULL};
	if (perl_parse(parent, NULL, 3, args, NULL) || perl_run(parent)) return 1;
	probe = TRUE;
	PerlInterpreter *child = perl_clone(parent, 0);
	probe = FALSE;
	if (!child || child != candidate) return 1;
	PERL_SET_CONTEXT(child);
	{
		dTHXa(child);
		if (PL_wump_task || S_wump_context_seen(aTHX) || SvIV(eval_pv("6 * 7", TRUE)) != 42)
			failed = TRUE;
	}
	perl_destruct(child);
	perl_free(child);
	PERL_SET_CONTEXT(parent);
	perl_destruct(parent);
	perl_free(parent);
	PERL_SYS_TERM();
#ifdef USE_PERL_SWITCH_LOCALE_CONTEXT
	if (!switches) return 1;
#endif
	if (failed) {
		fputs("FAIL: clone context was read before initialization\n", stderr);
		return 1;
	}
	puts("ok - clone initializes inactive context before its first locale switch and executes root code");
	return 0;
}
