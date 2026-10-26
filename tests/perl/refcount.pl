use strict;
use warnings;
use Config;
use Text::ParseWords 'shellwords';
use Cwd 'abs_path';

(@ARGV == 2 || @ARGV == 3 && $ARGV[2] eq '--tsan')
	or die "usage: $0 SOURCE BUILD [--tsan]\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV[0, 1];
my $tsan = @ARGV == 3;
my @libraries = map { $_ eq '-lperl' ? "$source/libperl.a" : $_ }
	shellwords($Config{perllibs});
my @common = (shellwords($Config{ccflags}), '-O2', '-pthread', "-I$source");
push @common, '-g', '-fsanitize=thread' if $tsan;
for my $language ('c', 'c++') {
	my $output = "$build/refcount-$language" . ($tsan ? '-tsan' : '');
	my @command = ($language eq 'c' ? shellwords($Config{cc}) : 'c++',
		@common, '-x', $language, 'tests/perl/refcount.c', '-x', 'none',
		"$source/libperl.a", shellwords($Config{ldflags}), @libraries, '-o', $output);
	system @command;
	$? == 0 or die "$language refcount fixture failed to compile: $?\n";
	system 'timeout', '60s', $output;
	$? == 0 or die "$language refcount stress failed: $?\n";
}
