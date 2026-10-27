package WumpTest;
use v5.42;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT = qw(check_program);

sub check_program ($code, $status, $pattern, $name) {
	my @switches = map { "-I$_" } grep { !ref } @INC;
	open my $child, '-|', $^X, @switches, '-e',
		q{use v5.42; BEGIN { open STDERR, '>&', STDOUT or die $! } } . $code
		or die "spawn $name: $!";
	my $output = do { local $/; <$child> };
	close $child;
	Test::More::is($?, $status << 8, "$name: wait status");
	Test::More::like($output, $pattern, "$name: output");
}

1;
