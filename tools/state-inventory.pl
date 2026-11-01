use v5.42;
use strict;
use warnings;
use File::Path 'make_path';
@ARGV == 1 or die "usage: perl $0 PERL_SOURCE\n";
my $source = shift;
open my $patchlevel, '<', "$source/patchlevel.h" or die $!;
my %version;
while (<$patchlevel>) {
	$version{$1} = $2 if /^\s*#\s*define\s+PERL_(REVISION|VERSION|SUBVERSION)\s+(\d+)/;
}
close $patchlevel or die $!;
join('.', @version{qw(REVISION VERSION SUBVERSION)}) eq '5.42.2'
	or die "inventory requires pinned Perl 5.42.2 source\n";
my %task;
open my $list, '<', 'perl/taskvars' or die $!;
while (<$list>) { chomp; $task{$_} = $. if length && !/^#/ }
close $list or die $!;
my %executor = map {$_ => 1} qw(sv_root sv_arenaroot sv_count body_arenas body_roots nomemok hash_rand_bits);
my %shared = map {$_ => 1} qw(strtab defstash incgv envgv modglobal main_cv main_root main_start beginav endav initav checkav unitcheckav regex_pad regex_padav sub_generation padlist_generation sv_yes sv_no sv_undef sv_zero sv_immortals padname_undef padname_const);
my %routed = map {$_ => 1} qw(rs ors_sv warnhook diehook dowarn dbargs);
my %phase = map {$_ => 1} qw(parser compiling comppad_name_fill comppad_name_floor min_intro_pending max_intro_pending padix padix_floor constpadix pad_reset_pending eval_begin_nest_depth);
make_path('docs');
open my $out, '>', 'docs/state-inventory.tsv' or die $!;
print {$out} "scope\tname\tdeclaration\tclassification\tassessment\tevidence\tnote\n";
my %counts;
for my $file (qw(intrpvar.h perlvars.h)) {
	open my $in, '<', "$source/$file" or die $!;
	while (<$in>) {
		next unless /^PERLVAR\w*\(\s*([IG]),\s*(\w+)/;
		my ($scope, $name) = ($1, $2);
		my ($owner, $assessment, $evidence, $note) = ('unresolved', 'unreviewed access paths', "Perl-5.42.2/$file:$.", 'Declared root/global storage; task or executor isolation is not established. Includes conditional declarations.');
		if ($scope eq 'I' && exists $task{$name}) {
			($owner, $assessment, $evidence, $note) = ('task-local', 'selected storage; pointees require separate review', "perl/taskvars:$task{$name};perl/apply.pl:307", 'Child storage is in wump_perl_task; main act and inactive execution use root fields.');
		} elsif ($scope eq 'I' && $executor{$name}) {
			($owner, $assessment, $evidence, $note) = ('executor-local', 'selected allocator storage', 'perl/apply.pl:315;perl/core/wump_alloc.c:48', 'P-local during execution; root fallback outside execution; merge after all users stop.');
		} elsif ($scope eq 'I' && $routed{$name}) {
			($owner, $assessment, $evidence, $note) = ('interpreter-global', 'cell/overlay routing on audited accesses', 'perl/core/wump_magic.c:93;perl/hooks.pl:1', 'Root fallback remains shared; active localized cells own their caches; direct field access is not redirected by this classification.');
			if ($name eq 'dbargs') {
				$evidence = 'perl/core/wump_core.c:415;perl/carp.pl:1';
				$note = 'Active cache resolves the current act-local DB::args binding; Carp localizes each caller_info invocation. Non-owning argument arrays cannot be published; general debugger state remains unaudited.';
			}
		} elsif ($scope eq 'I' && $shared{$name}) {
			($owner, $assessment, $evidence, $note) = ('intentionally-shared', 'bounded guards or phase restriction; not blanket concurrency certification', 'perl/core/wump_core.c:269;perl/core/wump_keys.c:22;perl/refcount.pl:5', 'Code/templates/namespaces/roots remain shared; payload mutation and lazy caches need their own protocol.');
		} elsif ($scope eq 'I' && $phase{$name}) {
			($owner, $assessment, $evidence, $note) = ('interpreter-global', 'compiler-restricted; reentrant callbacks need coverage', 'perl/active.pl:55;perl/core/wump_core.c:27', 'Not task-local. Parallel runtime compilation is rejected; automatic checkpoints defer in parser activity.');
		} elsif ($scope eq 'G') {
			($owner, $assessment, $evidence, $note) = ('interpreter-global', 'process-global declaration; Wump isolation unresolved', "Perl-5.42.2/$file:$.", 'Actually process-global, not per interpreter; upstream locks or constants are not a Wump concurrency audit.');
		}
		print {$out} join("\t", $scope, $name, "Perl-5.42.2/$file:$.", $owner, $assessment, $evidence, $note), "\n";
		$counts{$owner}++;
	}
	close $in or die $!;
}
for my $row (
	['Iwump_task', 'reserved compatibility slot; not the current task pointer'],
	['Iwump_publishing', 'reserved field; publication activity uses native TLS'],
	['Iwump_enabled', 'compile-time opt-in; selects Perl main entry'],
	['Iwump_keys_mutex', 'shared key-table native mutex; never held over scheduling'],
	['Iwump_keys_ready', 'interpreter construction/destruction lifecycle'],
	['Iwump_read_frame', 'inactive root fallback; active frames belong to task'],
	['Iwump_memory', 'per-interpreter registry, claims, pins and retirement domain'],
	['Iwump_context_seen', 'sticky atomic selection hint; not ownership or publication proof'],
) {
	print {$out} join("\t", 'Wump', $row->[0], 'perl/apply.pl:232', 'interpreter-global', 'explicit implementation field', 'perl/apply.pl:232', $row->[1]), "\n";
	$counts{'interpreter-global'}++;
}
close $out or die $!;
print "$_\t$counts{$_}\n" for sort keys %counts;
