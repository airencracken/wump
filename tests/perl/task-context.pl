use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

(@ARGV == 2 || @ARGV == 3 && $ARGV[2] eq '--tsan')
	or die "usage: $0 SOURCE BUILD [--tsan]\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV[0, 1];
my $tsan = @ARGV == 3;
my $output = "$build/task-context" . ($tsan ? '-tsan' : '');
my @libraries = shellwords($Config{perllibs});
my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}),
	'-O2', '-g', '-pthread', "-I$source",
	($tsan ? '-fsanitize=thread' : ()), 'tests/perl/task-context.c',
	"$source/libperl.a", shellwords($Config{ldflags}), @libraries, '-o', $output);
system @command;
$? == 0 or die "task-context fixture failed to compile: $?\n";
system 'timeout', '60s', $output;
$? == 0 or die "task-context fixture failed: $?\n";
