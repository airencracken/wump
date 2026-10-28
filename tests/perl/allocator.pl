use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
my $output = "$build/allocator";
my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}),
	'-O2', '-g', '-pthread', "-I$source", 'tests/perl/allocator.c',
	"$source/libperl.a", shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $output);
system @command;
$? == 0 or die "allocator fixture failed to compile: $?\n";
system 'timeout', '90s', $output;
$? == 0 or die "allocator fixture failed: $?\n";

if ($Config{ccflags} =~ /-fsanitize=thread\b/) {
	my $log = "$build/allocator-race.log";
	my $status;
	{
		local $ENV{TSAN_OPTIONS} = 'halt_on_error=1:exitcode=66';
		open my $saved_out, '>&', \*STDOUT or die "save stdout: $!\n";
		open my $saved_err, '>&', \*STDERR or die "save stderr: $!\n";
		open STDOUT, '>', $log or die "$log: $!\n";
		open STDERR, '>&', \*STDOUT or die "redirect stderr: $!\n";
		system 'timeout', '30s', $output, '--race';
		$status = $?;
		open STDOUT, '>&', $saved_out or die "restore stdout: $!\n";
		open STDERR, '>&', $saved_err or die "restore stderr: $!\n";
	}
	open my $report, '<', $log or die "$log: $!\n";
	local $/;
	my $text = <$report>;
	$status == (66 << 8) && $text =~ /ThreadSanitizer: data race/ && $text =~ /Perl_more_bodies/
		or die "TSan failed to detect the deliberate race in Perl's allocator ($status):\n$text";
	print "ok - TSan detects the deliberate race inside Perl_more_bodies\n";
}
