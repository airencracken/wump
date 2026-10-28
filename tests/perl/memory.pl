use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
for my $spec (['borrowed', 'c'], ['borrowed', 'c++'], ['reclamation', 'c'], ['retire-failure', 'c']) {
	my ($fixture, $language) = @$spec;
	my $target = "$build/$fixture" . ($language eq 'c++' ? '-cpp' : '');
	my @command = ($language eq 'c++' ? 'c++' : shellwords($Config{cc}), shellwords($Config{ccflags}),
		'-O2', '-g', '-pthread', "-I$source", '-x', $language, "tests/perl/$fixture.c", '-x', 'none',
		"$source/libperl.a", shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $target);
	push @command, '-Wl,--wrap=malloc' if $fixture eq 'retire-failure';
	system @command;
	$? == 0 or die "$fixture $language failed to compile: $?\n";
	system 'timeout', '90s', $target;
	$? == 0 or die "$fixture $language failed: $?\n";
}
