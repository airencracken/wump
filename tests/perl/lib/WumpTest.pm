package WumpTest;
use v5.42;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT = qw(check_program with_tasks act);
our $group;

# Test fixtures wait for their workers so assertions observe completed cleanup.
# Applications use explicit add/done/wait; no runtime tracks act ancestry.
sub with_tasks :prototype(&) ($code) {
	local $group = Wump::waitgroup();
	$code->();
	$group->wait;
	return;
}

sub act :prototype(&) ($code) {
	my $joined = $group;
	if (!$joined) { &Wump::act($code); return }
	$joined->add;
	my $spawned = eval { Wump::act(sub { $code->(); $joined->done }); 1 };
	if (!$spawned) {
		my $error = $@;
		$joined->done;
		die $error;
	}
	return;
}

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
