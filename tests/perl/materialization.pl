use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
for my $language ('c', 'c++') {
	my $target = "$build/opcode-materialization" . ($language eq 'c++' ? '-cpp' : '');
	my @command = ($language eq 'c++' ? shellwords($ENV{CXX} // 'c++') : shellwords($Config{cc}), shellwords($Config{ccflags}),
		'-O2', '-g', '-pthread', "-I$source", '-x', $language, 'tests/perl/opcode-materialization.c', '-x', 'none',
		"$source/libperl.a", '-Wl,--wrap=Perl_wump_lvalue_av', '-Wl,--wrap=Perl_wump_lvalue_hv',
		shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $target);
	system @command;
	$? == 0 or die "opcode materialization $language failed to compile: $?\n";
	system 'timeout', '90s', $target;
	$? == 0 or die "opcode materialization $language failed: $?\n";
}
my $log = "$build/opcode-materialization-unguarded.log";
my $status;
{
	open my $saved_out, '>&', \*STDOUT or die "save stdout: $!\n";
	open my $saved_err, '>&', \*STDERR or die "save stderr: $!\n";
	open STDOUT, '>', $log or die "$log: $!\n";
	open STDERR, '>&', \*STDOUT or die "redirect stderr: $!\n";
	system 'timeout', '30s', "$build/opcode-materialization", '--unguarded';
	$status = $?;
	open STDOUT, '>&', $saved_out or die "restore stdout: $!\n";
	open STDERR, '>&', $saved_err or die "restore stderr: $!\n";
}
open my $report, '<', $log or die "$log: $!\n";
local $/;
my $text = <$report>;
$status == 6 && $text =~ /materialized element must have a lifetime reference/
	or die "unguarded opcode did not expose its missing lifetime reference ($status):\n$text";
print "ok - bypassing materialization exposes the original opcode's missing lifetime reference\n";
