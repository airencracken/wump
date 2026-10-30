# Compile ordinary-context variants from the same patched native bodies.
# Public opcode addresses stay unchanged, including custom ppaddr hooks.
sub apply_ordinary {
	my ($source) = @_;
	my @specs = (
		(map { ['pp_hot.c', $_, "pp_$_"] } qw(const nextstate gvsv padsv iter unstack null pushmark)),
		['pp_hot.c', 'add', 'wump_write_impl_add'],
		['pp.c', 'modulo', 'wump_write_impl_modulo'],
	);
	my $prototypes = "/* Generated ordinary-context opcode declarations. */\n";
	my $plain = <<'C';
/* Generated from pinned, patched Perl opcode bodies. */
#define WUMP_ROOT_CONTEXT
#include "EXTERN.h"
#define PERL_IN_PP_HOT_C
#include "perl.h"
#include "regcomp.h"
#include "feature.h"
#include "wump_plain_ops.h"

C
	# An opcode callback can activate a context before its numeric store.
	# Retain the public guarded setter after activation; otherwise inline
	# the same native setter body with direct root-state lvalues.
	my $numeric = read_file("$source/sv.c");
	for my $name (qw(sv_setiv sv_setuv sv_setnv)) {
		my $marker = "#define Perl_$name wump_memory_impl_$name\n";
		my $at = index($numeric, $marker);
		my $start = index($numeric, "Perl_$name(", $at);
		my $end = index($numeric, "\n}\n", $start);
		$at >= 0 && $start >= 0 && $end >= 0 or die "missing ordinary numeric setter $name\n";
		my $body = substr($numeric, $start, $end + 3 - $start);
		$body =~ /\(pTHX_ ([^\n]+)\)\n/ or die "missing numeric setter parameters $name\n";
		my @arguments = map { /\b(\w+)\s*\z/ ? $1 : die "unknown setter argument\n" } split /,/, $1;
		$body =~ s/^Perl_\Q$name\E/S_wump_plain_$name/;
		my $fallback = "    if (S_wump_context_seen(aTHX)) {\n"
			. "        Perl_$name(aTHX_ " . join(', ', @arguments) . ");\n        return;\n    }\n";
		$body =~ s/\n\{\n/\n{\n$fallback/ or die "missing setter body $name\n";
		$plain .= "__attribute__((always_inline)) static inline void\n$body\n"
			. "#undef $name\n#define $name(sv, value) S_wump_plain_$name(aTHX_ (sv), (value))\n\n";
	}
	for my $spec (@specs) {
		my ($file, $name, $implementation) = @$spec;
		my $text = read_file("$source/$file");
		my $signature = "PP($implementation)\n{";
		my $start = index($text, $signature);
		my $end = index($text, "\n}\n", $start);
		$start >= 0 && $end >= 0 or die "missing ordinary opcode source $name\n";
		my $gate = "    if (!S_wump_context_seen(aTHX)) return Perl_wump_plain_$name(aTHX);\n";
		my $body = substr($text, $start, $end + 3 - $start);
		$body =~ s/\Q$gate\E//g;
		$body =~ s/\QPP($implementation)\E/PP(wump_plain_$name)/;
		$body = "__attribute__((always_inline)) inline\n$body";
		$plain .= "$body\n";
		$prototypes .= "OP *Perl_wump_plain_$name(pTHX);\n";
		edit($file, "PP(pp_$name)\n{\n", "PP(pp_$name)\n{\n$gate");
	}
	my $run = read_file("$source/run.c");
	my $signature = "Perl_runops_standard(pTHX)\n{";
	my $start = index($run, $signature);
	my $end = index($run, "\n}\n", $start);
	$start >= 0 && $end >= 0 or die "missing ordinary runloop source\n";
	my $gate = "    if (!S_wump_context_seen(aTHX)) return Perl_wump_plain_runops(aTHX);\n";
	my $body = substr($run, $start, $end + 3 - $start);
	$body =~ s/\Q$gate\E//g;
	my $active = "    if (PL_wump_task) return Perl_wump_runops(aTHX);\n";
	$body =~ s/\Q$active\E//g;
	my $canonical = $body;
	$canonical =~ s/\Q$signature\E\n/$signature\n$active$gate/;
	substr($run, $start, $end + 3 - $start, $canonical);
	write_file("$source/run.c", $run);
	# A root loop can call these bodies directly when the op still has its
	# native public entry. Replaced ppaddr hooks retain ordinary dispatch.
	# Reenter the standard loop after activation before probing the next op.
	$plain .= <<'C';
int
Perl_wump_plain_runops(pTHX)
{
    OP *op = PL_op;
    while (op) {
        if (S_wump_context_seen(aTHX)) return Perl_runops_standard(aTHX);
        PERL_DTRACE_PROBE_OP(op);
        OP *next;
        switch (op->op_type) {
C
	for my $spec (@specs) {
		my $name = $spec->[1];
		my $opcode = uc($name);
		$plain .= "        case OP_$opcode:\n"
			. "            next = op->op_ppaddr == Perl_pp_$name\n"
			. "                ? Perl_wump_plain_$name(aTHX) : op->op_ppaddr(aTHX);\n            break;\n";
	}
	$plain .= <<'C';
        default:
            next = op->op_ppaddr(aTHX);
            break;
        }
        PL_op = op = next;
    }
    PERL_ASYNC_CHECK();
    TAINT_NOT;
    return 0;
}
C
	$prototypes .= "int Perl_wump_plain_runops(pTHX);\n";
	# Numeric setters keep their complete native implementation and validation.
	# An interpreter which has never activated a context has no actor claims.
	my $sv = read_file("$source/sv.c");
	for my $name (qw(sv_setiv sv_setuv sv_setnv)) {
		my $marker = "/* Wump mutation wrapper: $name */\n";
		my $at = index($sv, $marker);
		$at >= 0 or die "missing ordinary numeric setter $name\n";
		my $open = index($sv, "\n{\n", $at);
		my $signature = substr($sv, $at + length($marker), $open - $at - length($marker));
		$signature =~ /\QPerl_$name\E\(pTHX_ (.*)\)/s or die "missing setter parameters $name\n";
		my @arguments = map { /\b(\w+)\s*\z/ ? $1 : die "unknown setter argument\n" } split /,/, $1;
		my $early = "    if (!S_wump_context_seen(aTHX)) {\n"
			. "        wump_memory_impl_$name(aTHX_ " . join(', ', @arguments) . ");\n        return;\n    }\n";
		substr($sv, $open + 3, 0, $early) unless substr($sv, $open + 3, length($early)) eq $early;
	}
	write_file("$source/sv.c", $sv);
	write_file("$source/wump_plain_ops.h", $prototypes);
	write_file("$source/wump_plain_ops.c", $plain);
}
1;
