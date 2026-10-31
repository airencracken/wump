use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';
@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map {abs_path($_) // die "$_: $!"} @ARGV;
for my $language ('c', 'c++') {
	my $target = "$build/scalar-lookup-$language";
	my @command = ($language eq 'c++' ? shellwords($ENV{CXX} // 'c++') : shellwords($Config{cc}),
		shellwords($Config{ccflags}), '-O2', '-g', '-pthread', "-I$source",
		'-x', $language, 'tests/perl/scalar-lookup.c', '-x', 'none', "$source/libperl.a",
		'-Wl,--wrap=Perl_wump_gv_sv', shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $target);
	system @command;
	$? == 0 or die "$language scalar lookup fixture failed to compile: $?\n";
	for my $slots (1, 4) {
		local $ENV{WUMPPROCS} = $slots;
		system 'timeout', '90s', $target, "-I$source/lib";
		$? == 0 or die "$language scalar lookup fixture failed on $slots slots: $?\n";
	}
}
