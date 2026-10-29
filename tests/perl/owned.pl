use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
my $output = "$build/owned";
my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}),
	'-O2', '-g', '-pthread', "-I$source", 'tests/perl/owned.c',
	"$source/libperl.a", shellwords($Config{ldflags}), shellwords($Config{perllibs}),
	'-Wl,--wrap=pthread_mutex_lock', '-o', $output);
system @command;
$? == 0 or die "owned-value fixture failed to compile: $?\n";
system 'timeout', '60s', $output;
$? == 0 or die "owned-value fixture failed: $?\n";
