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
$header .= "struct wump_cv_slot;\nstruct wump_perl_task {\n";
for my $name (@vars) {
	exists $types{$name} or die "Missing upstream interpreter field: $name\n";
	$header .= "\t$types{$name} I$name;\n";
}
$header .= <<'C';
	PerlInterpreter *interp;
	CV *entry;
	struct wump_cv_slot *cvs;
	UV id;
	int initialized, finished;
};
I32 *Perl_wump_cv_depth(pTHX_ const CV *cv);
PADLIST **Perl_wump_cv_padlist(CV *cv);
void Perl_wump_cv_prepare(pTHX_ CV *cv);
void Perl_wump_boot(pTHX);
SV **Perl_wump_gv_sv(GV *gv);
AV **Perl_wump_gv_av(GV *gv);
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
my $gv = read_file("$source/gv.h");
$gv =~ s/\QGvGP(gv)->gp_sv ?\E/GvSV(gv) ?/g;
$gv =~ s/\Q&(GvGP(gv)->gp_sv) :\E/\&GvSV(gv) :/g;
$gv =~ s/\QGvGP(gv)->gp_av ?\E/GvAV(gv) ?/g;
$gv =~ s/\QGvGP(gv)->gp_av :\E/GvAV(gv) :/g;
write_file("$source/gv.h", $gv);
edit('run.c', '#define PERL_IN_RUN_C', "#define PERL_IN_RUN_C\n/* Wump core implementation is built into both perl and miniperl. */");
my $run = read_file("$source/run.c");
my $include = "\n#include \"wump_core.c\"\n";
write_file("$source/run.c", $run . $include) unless index($run, $include) >= 0;
edit('perl.c', 'boot_core_UNIVERSAL();', "boot_core_UNIVERSAL();\n    Perl_wump_boot(aTHX);");
for my $pair (
	["$FindBin::Bin/core/wump_core.c", "$source/wump_core.c"],
	["$FindBin::Bin/../runtime/include/wump.h", "$source/wump.h"],
	["$FindBin::Bin/../runtime/src/internal.h", "$source/wump_runtime_internal.h"],
) {
	write_file($pair->[1], read_file($pair->[0]));
}
print "Applied Wump task-state integration to $source\n";
