use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';
@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
my $target = "$build/numeric-admission";
my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}), '-O2', '-g', '-pthread',
	"-I$source", 'tests/perl/numeric-admission.c', "$source/libperl.a",
	'-Wl,--wrap=pthread_mutex_lock', '-Wl,--wrap=posix_memalign',
	shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $target);
system @command;
$? == 0 or die "numeric admission fixture failed to compile: $?\n";
system 'timeout', '90s', $target;
$? == 0 or die "numeric admission fixture failed: $?\n";
my $log = "$build/numeric-admission-unguarded.log";
my $status;
{
	open my $saved_out, '>&', \*STDOUT or die "save stdout: $!\n";
	open my $saved_err, '>&', \*STDERR or die "save stderr: $!\n";
	open STDOUT, '>', $log or die "$log: $!\n";
	open STDERR, '>&', \*STDOUT or die "redirect stderr: $!\n";
	system 'timeout', '30s', $target, '--unguarded-reader';
	$status = $?;
	open STDOUT, '>&', $saved_out or die "restore stdout: $!\n";
	open STDERR, '>&', $saved_err or die "restore stderr: $!\n";
}
open my $report, '<', $log or die "$log: $!\n";
local $/;
my $text = <$report>;
close $report or die "$log: $!\n";
$status == 6 && $text =~ /metadata writer passed an admitted numeric reader/
	or die "missing numeric announcement did not expose early writer admission ($status):\n$text";
print "ok - omitting one numeric announcement admits the metadata writer too early\n";
