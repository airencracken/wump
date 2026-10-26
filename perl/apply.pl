#!/usr/bin/perl
use strict;
use warnings;
use FindBin;

@ARGV == 1 or die "usage: $0 SOURCE_DIRECTORY\n";
my $source = $ARGV[0];
sub read_file {
	my ($path) = @_;
	open my $fh, '<', $path or die "$path: $!\n";
	local $/;
	return <$fh>;
}
sub write_file {
	my ($path, $text) = @_;
	return if -f $path && read_file($path) eq $text;
	if (-f $path && !-w $path) {
		chmod((stat($path))[2] | 0200, $path) or die "chmod $path: $!\n";
	}
	open my $fh, '>', $path or die "$path: $!\n";
	print {$fh} $text or die "$path: $!\n";
	close $fh or die "$path: $!\n";
}
sub edit {
	my ($file, $old, $new) = @_;
	my $text = read_file("$source/$file");
	return if index($text, $new) >= 0;
	my $count = $text =~ s/\Q$old\E/$new/g;
	$count == 1 or die "$file: expected one patch location, found $count\n";
	write_file("$source/$file", $text);
}
my @vars = grep { length && !/^#/ } split /\n/, read_file("$FindBin::Bin/taskvars");
my $intrp = read_file("$source/intrpvar.h");
my %types;
while ($intrp =~ /PERLVAR(?:I|IC)?\(\s*I,\s*(\w+),\s*([^,\)]+)(?:,[^\)]*)?\)/g) {
	my ($name, $type) = ($1, $2);
	$type =~ s/\s+$//;
	$types{$name} = $type;
}
my $header = "/* Generated from Perl's intrpvar.h by perl/apply.pl. */\n";
$header .= "struct wump_cv_slot;\nstruct wump_regex_slot;\nstruct wump_local;\nstruct wump_perl_task {\n";
for my $name (@vars) {
	exists $types{$name} or die "Missing upstream interpreter field: $name\n";
	$header .= "\t$types{$name} I$name;\n";
}
$header .= <<'C';
	PerlInterpreter *interp;
	CV *entry;
	struct wump_cv_slot *cvs;
	struct wump_regex_slot *regexes;
	struct wump_local *locals;
	UV id;
	int initialized, finished;
};
I32 *Perl_wump_cv_depth(pTHX_ const CV *cv);
PADLIST **Perl_wump_cv_padlist(CV *cv);
void Perl_wump_cv_prepare(pTHX_ CV *cv);
void Perl_wump_boot(pTHX);
SV **Perl_wump_gv_sv(GV *gv);
AV **Perl_wump_gv_av(GV *gv);
void Perl_wump_pm_stamp(pTHX_ PMOP *pm);
SV **Perl_wump_pm_slot(pTHX_ PMOP *pm);
REGEXP *Perl_wump_pm_get(pTHX_ PMOP *pm);
bool Perl_wump_pm_native(pTHX_ PMOP *pm, REGEXP *rx);
HV *Perl_wump_regex_names(pTHX_ HV *original);
HV **Perl_wump_gv_hv(GV *gv);
SV *Perl_wump_localize(pTHX_ GV *gv, char kind);
void Perl_wump_local_elements_check(pTHX);
void Perl_wump_save_defsv(pTHX);
C
write_file("$source/wump_task_types.h", $header);
edit('perl.h', "struct interpreter {\n#  include \"intrpvar.h\"\n};",
	"#include \"wump_task_types.h\"\nstruct interpreter {\n#  include \"intrpvar.h\"\n    struct wump_perl_task *Iwump_task;\n};");
my $vars = "\n/* Wump execution state: root execution retains the upstream fields. */\n";
$vars .= "#if defined(MULTIPLICITY)\n#define PL_wump_task (aTHX->Iwump_task)\n";
for my $name (@vars) {
	$vars .= "#undef PL_$name\n#define PL_$name (*(PL_wump_task ? &PL_wump_task->I$name : &aTHX->I$name))\n";
}
$vars .= "#endif\n";
write_file("$source/wump_task_embed.h", $vars);
my $embed = read_file("$source/embedvar.h");
$embed =~ s/\n\/\* Wump execution state:.*\z//s;
write_file("$source/embedvar.h", $embed);
edit('perl.h', '#  include "embedvar.h"', "#  include \"embedvar.h\"\n#  include \"wump_task_embed.h\"");
edit('inline.h', 'return &((XPVCV*)SvANY(sv))->xcv_depth;',
	"dTHX;\n    return Perl_wump_cv_depth(aTHX_ sv);");
edit('cv.h', '&(((XPVCV*)MUTABLE_PTR(SvANY(sv)))->xcv_padlist_u.xcv_padlist)))',
	'Perl_wump_cv_padlist((CV *)(sv))))');
edit('inline.h', 'cx->blk_sub.olddepth = CvDEPTH(cv);',
	"Perl_wump_cv_prepare(aTHX_ cv);\n    cx->blk_sub.olddepth = CvDEPTH(cv);");
edit('gv.h', "#define GvSV(gv)\t(GvGP(gv)->gp_sv)",
	"#define GvSV(gv)\t(*Perl_wump_gv_sv((GV *)(gv)))");
edit('gv.h', "#define GvAV(gv)\t(GvGP(gv)->gp_av)",
	"#define GvAV(gv)\t(*Perl_wump_gv_av((GV *)(gv)))");
edit('gv.h', "#define GvHV(gv)\t((GvGP(gv))->gp_hv)",
	"#define GvHV(gv)\t(*Perl_wump_gv_hv((GV *)(gv)))");
my $gv = read_file("$source/gv.h");
$gv =~ s/\QGvGP(gv)->gp_sv ?\E/GvSV(gv) ?/g;
$gv =~ s/\Q&(GvGP(gv)->gp_sv) :\E/\&GvSV(gv) :/g;
$gv =~ s/\QGvGP(gv)->gp_av ?\E/GvAV(gv) ?/g;
$gv =~ s/\QGvGP(gv)->gp_av :\E/GvAV(gv) :/g;
$gv =~ s/\QGvGP(gv)->gp_hv ?\E/GvHV(gv) ?/g;
$gv =~ s/\QGvGP(gv)->gp_hv :\E/GvHV(gv) :/g;
$gv =~ s/\QGvGP(gv_HVadd(gv))->gp_hv\E/GvHV(gv_HVadd(gv))/g;
$gv =~ s/\Q&(GvGP(gv_SVadd(gv))->gp_sv)\E/\&GvSV(gv_SVadd(gv))/g;
$gv =~ s/\QGvGP(gv_AVadd(gv))->gp_av\E/GvAV(gv_AVadd(gv))/g;
write_file("$source/gv.h", $gv);
for my $spec ([scalar => 'SV', 's'], [ary => 'AV', 'a'], [hash => 'HV', 'h']) {
	my ($name, $type, $kind) = @$spec;
	my $start = "Perl_save_$name(pTHX_ GV *gv)\n{";
	edit('scope.c', $start, "$start\n    if (PL_wump_task) return ($type *)Perl_wump_localize(aTHX_ gv, '$kind');");
}
edit('scope.c', "Perl_save_gp(pTHX_ GV *gv, I32 empty)\n{",
	"Perl_save_gp(pTHX_ GV *gv, I32 empty)\n{\n    if (PL_wump_task) croak(\"Wump: typeglob localization in a task is not supported yet\");");
edit('perl.h', "# define SAVE_DEFSV                \\\n", "# define SAVE_DEFSV (PL_wump_task ? Perl_wump_save_defsv(aTHX) : (void)WUMP_ROOT_SAVE_DEFSV)\n# define WUMP_ROOT_SAVE_DEFSV       \\\n");
edit('pp.c', "S_localise_gv_slot(pTHX_ GV *gv, U8 type)\n{",
	"S_localise_gv_slot(pTHX_ GV *gv, U8 type)\n{\n    if (PL_wump_task) croak(\"Wump: reference alias localization in a task is not supported yet\");");
for my $file ('pp.c', 'pp_hot.c') {
	my @ops = $file eq 'pp.c' ? qw(aslice hslice) : qw(aelem helem multideref);
	for my $op (@ops) {
		my $start = "PP(pp_$op)\n{";
		edit($file, $start, "$start\n    Perl_wump_local_elements_check(aTHX);");
	}
}
edit('pp.c', "S_do_delete_local(pTHX)\n{",
	"S_do_delete_local(pTHX)\n{\n    Perl_wump_local_elements_check(aTHX);");
edit('run.c', '#define PERL_IN_RUN_C', "#define PERL_IN_RUN_C\n/* Wump core implementation is built into both perl and miniperl. */");
my $run = read_file("$source/run.c");
my $include = "\n#include \"wump_core.c\"\n";
write_file("$source/run.c", $run . $include) unless index($run, $include) >= 0;
edit('perl.c', 'boot_core_UNIVERSAL();', "boot_core_UNIVERSAL();\n    Perl_wump_boot(aTHX);");
edit('op.h', "    OP *\top_code_list;\t/* list of (?{}) code blocks */",
	"    OP *\top_code_list;\t/* list of (?{}) code blocks */\n    U64 op_wump_id;\n    U8 op_wump_runtime;");
edit('op.h', "#define PM_GETRE_raw(o)\t(REGEXP*)(PL_regex_pad[(o)->op_pmoffset])",
	"#define PM_GETRE_raw(o)\t(REGEXP*)(PL_regex_pad[(o)->op_pmoffset])\n/* Wump keeps compiler ownership in op.c and isolates execution below. */");
my $op = read_file("$source/op.h");
my $macros = <<'C';
/* Wump regex execution slots; op.c always owns the original templates. */
#if defined(USE_ITHREADS) && !defined(PERL_IN_OP_C)
#undef PM_GETRE_raw
#undef PM_GETRE
#undef PM_SETRE_raw
#undef PM_SETRE
#define PM_GETRE_raw(o) ((REGEXP *)*Perl_wump_pm_slot(aTHX_ (PMOP *)(o)))
#define PM_GETRE(o) Perl_wump_pm_get(aTHX_ (PMOP *)(o))
#define PM_SETRE_raw(o,r) STMT_START { \
    *Perl_wump_pm_slot(aTHX_ (PMOP *)(o)) = MUTABLE_SV(r); \
} STMT_END
#define PM_SETRE(o,r) STMT_START { \
    REGEXP *const _wump_rx = (r); \
    assert(_wump_rx); \
    PM_SETRE_raw(o, _wump_rx); \
} STMT_END
#endif
C
my $anchor = '/* Currently these PMf flags occupy a single 32-bit word.';
unless (index($op, $macros) >= 0) {
	$op =~ s/\Q$anchor\E/$macros\n$anchor/ or die "op.h: missing PM flag anchor\n";
	write_file("$source/op.h", $op);
}
edit('op.c', 'NewOp(1101, pmop, 1, PMOP);',
	"NewOp(1101, pmop, 1, PMOP);\n    Perl_wump_pm_stamp(aTHX_ pmop);");
edit('op.c', '/* runtime pattern: build chain of regcomp etc ops */',
	"/* runtime pattern: build chain of regcomp etc ops */\n        pm->op_wump_runtime = 1;");
edit('regexec.c', 'Newxz(PL_reg_curpm, 1, PMOP);',
	"Newxz(PL_reg_curpm, 1, PMOP);\n        Perl_wump_pm_stamp(aTHX_ PL_reg_curpm);");
my $exec = read_file("$source/regexec.c");
$exec =~ s/hv_iterinit\(RXp_PAREN_NAMES\((prog|rx)\)\)/hv_iterinit(Perl_wump_regex_names(aTHX_ RXp_PAREN_NAMES($1)))/g;
$exec =~ s/HV \*hv\s*= RXp_PAREN_NAMES\(rx\);/HV *hv = Perl_wump_regex_names(aTHX_ RXp_PAREN_NAMES(rx));/g;
write_file("$source/regexec.c", $exec);
edit('regexec.c', 'U8 flags = (CXp_SUB_RE |',
	"Perl_wump_cv_prepare(aTHX_ newcv);\n                    U8 flags = (CXp_SUB_RE |");
edit('pp_hot.c', 'truebase = prog->mother_re',
	'truebase = (prog->mother_re && !Perl_wump_pm_native(aTHX_ pm, rx))');
my $hot = read_file("$source/pp_hot.c");
$hot =~ s/!RX_PRELEN\(rx\) && PL_curpm && !prog->mother_re/!RX_PRELEN(rx) \&\& PL_curpm \&\& (!prog->mother_re || Perl_wump_pm_native(aTHX_ pm, rx))/g;
$hot =~ s/\QPL_regex_pad[pm->op_pmoffset]\E/*Perl_wump_pm_slot(aTHX_ pm)/g;
$hot =~ s/\QPL_regex_pad[dynpm->op_pmoffset]\E/*Perl_wump_pm_slot(aTHX_ dynpm)/g;
write_file("$source/pp_hot.c", $hot);
edit('sv.c', 'SvREADONLY_off(PL_regex_pad[(*pmp)->op_pmoffset]);',
	'SvREADONLY_off(*Perl_wump_pm_slot(aTHX_ *pmp));');
for my $pair (
	["$FindBin::Bin/core/wump_core.c", "$source/wump_core.c"],
	["$FindBin::Bin/core/wump_local.c", "$source/wump_local.c"],
	["$FindBin::Bin/../runtime/include/wump.h", "$source/wump.h"],
	["$FindBin::Bin/../runtime/src/internal.h", "$source/wump_runtime_internal.h"],
) {
	write_file($pair->[1], read_file($pair->[0]));
}
print "Applied Wump task-state integration to $source\n";
