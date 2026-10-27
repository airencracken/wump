#include "EXTERN.h"
#include "perl.h"
#include <stdio.h>

static UV stale_id;

static int execute(pTHX_ char *body, char *library, int expected) {
	char program[] = "interpreter-entry", option[] = "-e", modules[] = "-Iperl/lib";
	char *args[] = {program, modules, library, option, body, NULL};
	if (perl_parse(aTHX_ NULL, 5, args, NULL)) return 1;
	if (stale_id) {
		/* Keep only the ID across interpreter destruction. Never retain
		 * an SV allocated by a freed interpreter. */
		SV *id = newSVuv(stale_id);
		SV *object = newRV_noinc(id);
		sv_bless(object, gv_stashpvs("Wump::Channel", GV_ADD));
		SvREADONLY_on(id);
		sv_setsv(get_sv("main::stale", GV_ADD), object);
		SvREFCNT_dec(object);
	}
	int status = perl_run(aTHX);
	if (status != expected || PL_wump_task != NULL) {
		fprintf(stderr, "entry fixture: status %d, expected %d, task %p\n",
			status, expected, (void *)PL_wump_task);
		return 1;
	}
	return 0;
}

int main(int argc, char **argv, char **env) {
	if (argc != 2) return 1;
	PERL_SYS_INIT3(&argc, &argv, &env);
	char first[] =
		"use v5.42; use Wump;"
		"our ($mode, @values, %options, $old, $destroyed);"
		"$mode = 'base'; @values = (1, 2); %options = (base => 1); $destroyed = 0;"
		"package Owned { sub DESTROY { $main::destroyed++ } }"
		"$old = chan(1); $old->send(bless {}, 'Owned');"
		"my $park = chan;"
		"act {"
		" local $mode = bless {}, 'Owned'; local $values[10] = 'private';"
		" pocket $options{owned} = bless {}, 'Owned';"
		" my $length = 3; local $/ = bless \\$length, 'Owned'; $park->recv;"
		"}; yield;"
		"local $mode = bless {}, 'Owned'; act { die 'queued child ran' };";
	char second[] =
		"use Wump; our $stale;"
		"eval { $stale->recv }; die qq{stale channel check: $@} unless $@ =~ /inactive runtime/;"
		"my $out = chan(1); scope { act { $out->send(42) } };"
		"die 'restart failed' unless $out->recv == 42;";
	char deadlock[] = "use Wump; my $park = chan; $park->recv;";
	char recovered[] =
		"use Wump; my $out = chan; act { $out->send(99) };"
		"die 'deadlock recovery' unless $out->recv == 99;";
	char *programs[] = {first, second, deadlock, recovered};
	int statuses[] = {0, 0, 2, 0};
	for (size_t n = 0; n < sizeof(programs) / sizeof(programs[0]); n++) {
		PerlInterpreter *interp = perl_alloc();
		if (!interp) return 1;
		PERL_SET_CONTEXT(interp);
		perl_construct(interp);
		dTHXa(interp);
		PL_perl_destruct_level = 2;
		if (execute(aTHX_ programs[n], argv[1], statuses[n])) return 1;
		if (n == 0) {
			/* Observe original slots after actual scheduler teardown,
			 * outside every act, using the surviving interpreter stacks. */
			eval_pv("die 'cleanup count' unless $main::destroyed == 5;"
				"die 'global scalar' unless $main::mode eq 'base';"
				"die 'array extent' unless @main::values == 2;"
				"die 'global hash' unless keys(%main::options) == 1 && $main::options{base};"
				"die 'separator' unless $/ eq qq{\\n};", TRUE);
			stale_id = SvUV(SvRV(get_sv("main::old", 0)));
		}
		int status = perl_destruct(interp);
		perl_free(interp);
		if (status != statuses[n]) return 1;
	}
	PERL_SYS_TERM();
	puts("ok - interpreter entry preserves global slots, rejects stale channel IDs, and restarts after shutdown and deadlock");
	return 0;
}
