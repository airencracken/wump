use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
my $output = "$build/interpreter-entry";
my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}),
	'-O2', '-g', '-pthread', "-I$source", 'tests/perl/entry.c',
	"$source/libperl.a", shellwords($Config{ldflags}),
	shellwords($Config{perllibs}), '-o', $output);
system @command;
$? == 0 or die "interpreter-entry fixture failed to compile: $?\n";
system 'timeout', '60s', $output, "-I$source/lib";
$? == 0 or die "interpreter-entry fixture failed: $?\n";
