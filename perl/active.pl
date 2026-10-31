# Generate bounded active-context variants from the same patched native bodies.
# A C frame belongs to one act even when that act migrates. Cache its task
# pointer, never a native TLS address or the current executor's allocator.
sub apply_active {
	my ($source, $vars) = @_;
	my $active = <<'C';
/* Generated from pinned, patched Perl opcode bodies. */
#include "EXTERN.h"
#define PERL_IN_PP_HOT_C
#include "perl.h"
#include "regcomp.h"
#include "feature.h"
#include "wump_runtime_internal.h"
#include "wump_scalar.h"

OP *Perl_wump_read_impl_add(pTHX);
OP *Perl_wump_read_impl_modulo(pTHX);

/* Header inline helpers retain dynamic context selection. Only the opcode
 * bodies and their dispatcher use the act owned by this C invocation. */
#undef PL_wump_task
#define PL_wump_task wump_task
C
	for my $name (@$vars) {
		$active .= "#undef PL_$name\n#define PL_$name (*(wump_main ? &aTHX->I$name : &wump_task->I$name))\n";
	}
	$active .= <<'C';

PERL_STATIC_INLINE SV **
S_wump_active_scalar(pTHX_ struct wump_perl_task *task, GV *gv)
{
    SV **slot = S_wump_private_scalar(aTHX_ task, gv);
    return slot ? slot : Perl_wump_gv_sv(gv);
}
#undef GvSV
#define GvSV(gv) (*S_wump_active_scalar(aTHX_ wump_task, (GV *)(gv)))
C
	my @specs = (
		(map { ['pp_hot.c', $_] } qw(const nextstate gvsv padsv iter unstack null pushmark add)),
		['pp.c', 'modulo'],
	);
	for my $spec (@specs) {
		my ($file, $name) = @$spec;
		my $text = read_file("$source/$file");
		my $start = index($text, "PP(pp_$name)\n{");
		my $end = index($text, "\n}\n", $start);
		$start >= 0 && $end >= 0 or die "missing active opcode source $name\n";
		my $body = substr($text, $start, $end + 3 - $start);
		$body =~ s/    if \(!S_wump_context_seen\(aTHX\)\) return Perl_wump_plain_\Q$name\E\(aTHX\);\n//g;
		$body =~ s/\QPP(pp_$name)\E/__attribute__((always_inline)) static inline OP *\nS_wump_active_$name(pTHX_ struct wump_perl_task *wump_task, bool wump_main)/;
		$body =~ s/\n\{\n/\n{\n    PERL_UNUSED_ARG(wump_task);\n    PERL_UNUSED_ARG(wump_main);\n/;
		$active .= "\n$body";
	}
	$active .= <<'C';

int
Perl_wump_active_runops(pTHX_ struct wump_perl_task *wump_task)
{
    assert(wump_task && wump_task->interp == aTHX);
    const bool wump_main = wump_task->main != 0;
    unsigned ticks = 256;
    OP *op = PL_op;
    bool parallel = wump_nprocs() > 1;
    PERL_DTRACE_PROBE_OP(op);
    while (op) {
        PL_op = op;
        if (parallel && (op->op_type == OP_ENTEREVAL || op->op_type == OP_REQUIRE
            || op->op_type == OP_DOFILE))
            croak("Wump: runtime compilation is not supported during parallel execution");
        switch (op->op_type) {
C
	for my $spec (@specs) {
		my $name = $spec->[1];
		my $opcode = uc($name);
		$active .= "        case OP_$opcode:\n"
			. "            op = op->op_ppaddr == Perl_pp_$name\n"
			. "                ? S_wump_active_$name(aTHX_ wump_task, wump_main) : op->op_ppaddr(aTHX);\n"
			. "            break;\n";
	}
	$active .= <<'C';
        default:
            op = op->op_ppaddr(aTHX);
            break;
        }
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
C
	write_file("$source/wump_active_ops.c", $active);
}
1;
