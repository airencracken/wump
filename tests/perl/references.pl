use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
for my $language ('c', 'c++') {
	my $target = "$build/opcode-references" . ($language eq 'c++' ? '-cpp' : '');
	my @command = ($language eq 'c++' ? 'c++' : shellwords($Config{cc}), shellwords($Config{ccflags}),
		'-O2', '-g', '-pthread', "-I$source", '-x', $language, 'tests/perl/opcode-references.c', '-x', 'none',
		"$source/libperl.a", '-Wl,--wrap=Perl_wump_load_rv',
		shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $target);
	system @command;
	$? == 0 or die "opcode references $language failed to compile: $?\n";
	system 'timeout', '90s', $target;
	$? == 0 or die "opcode references $language failed: $?\n";
}
my $log = "$build/opcode-references-unguarded.log";
my $status;
{
	open my $saved_out, '>&', \*STDOUT or die "save stdout: $!\n";
	open my $saved_err, '>&', \*STDERR or die "save stderr: $!\n";
	open STDOUT, '>', $log or die "$log: $!\n";
	open STDERR, '>&', \*STDOUT or die "redirect stderr: $!\n";
	system 'timeout', '30s', "$build/opcode-references", '--unguarded';
	$status = $?;
	open STDOUT, '>&', $saved_out or die "restore stdout: $!\n";
	open STDERR, '>&', $saved_err or die "restore stderr: $!\n";
}
open my $report, '<', $log or die "$log: $!\n";
local $/;
my $text = <$report>;
$status == 6 && $text =~ /extracted referent must have a lifetime reference/
	or die "unguarded opcode did not expose its missing lifetime reference ($status):\n$text";
print "ok - bypassing reference capture exposes the missing referent lifetime reference\n";
