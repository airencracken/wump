use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

(@ARGV == 2 || @ARGV == 3 && $ARGV[2] eq '--expect-upstream-bugs')
	or die "usage: $0 SOURCE BUILD [--expect-upstream-bugs]\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV[0, 1];
my $expected = @ARGV == 3 ? 1 : 0;
for my $case (
	['deferred-owner', 'resolved=1 target_null=1 owner_alive=' . $expected],
	['deferred-target', 'resolved=1 target_alive=' . (1 - $expected)],
) {
	my ($name, $result) = @$case;
	my $target = "$build/$name";
	my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}), '-O2', '-g',
		"-I$source", "tests/perl/core-bugs/$name.c", "$source/libperl.a",
		'-Wl,-E', shellwords($Config{ldflags}), shellwords($Config{perllibs}), '-o', $target);
	system @command;
	$? == 0 or die "$name reproducer failed to compile: $?\n";
	open my $child, '-|', 'timeout', '30s', $target or die "run reproducer: $!\n";
	my $output = do { local $/; <$child> };
	close $child;
	my $status = $?;
	print $output;
	$status == $expected << 8 && $output eq "$result\n"
		or die "unexpected $name result ($status), expected exit $expected\n";
	print $expected ? "ok - pristine Perl reproduces $name\n" : "ok - $name regression passes\n";
}
