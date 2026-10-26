use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
no warnings 'experimental::args_array_with_signatures';

my @received;
run {
	my $ch = chan;
	act { $ch->send('from a Perl task') };
	push @received, scalar $ch->recv;
};
is_deeply(\@received, ['from a Perl task'], 'unbuffered channel schedules a Perl closure');

sub worker ($id) {
	my $local = "local-$id";
	my @args = @_;
	$_ = "default-$id";
	eval { die "caught-$id\n" };
	my $error = $@;
	yield;
	my $after = $@;
	sleep 0.0001;
	return [$id, $local, \@args, $_, $error, $after];
}
@received = ();
run {
	my $out = chan(2);
	for my $id (1..12) {
		act { $out->send(worker($id)) };
	}
	push @received, scalar $out->recv for 1..12;
};
@received = sort { $a->[0] <=> $b->[0] } @received;
is_deeply(\@received, [map { [$_, "local-$_", [$_], "default-$_", "caught-$_\n", "caught-$_\n"] } 1..12],
	'overlapping calls isolate lexicals, arguments, default scalar, and caught exceptions');

my ($copy, $reference, @open, @closed, @errors);
my $shared = {value => 42};
run {
	my $ch = chan(3);
	my $value = 'before';
	$ch->send($value);
	$value = 'after';
	$ch->send($shared);
	$ch->send(undef);
	$ch->close;
	$copy = $ch->recv;
	$reference = $ch->recv;
	@open = $ch->recv;
	@closed = $ch->recv;
	eval { $ch->send(1) }; push @errors, $@;
	eval { $ch->close }; push @errors, $@;
};
is($copy, 'before', 'send copies the scalar');
is($reference, $shared, 'references retain their identity');
is_deeply(\@open, [undef, 1], 'undef is a valid message');
is_deeply(\@closed, [undef, ''], 'closed drained channel reports false in list context');
like($errors[0], qr/send on closed/, 'closed send is catchable inside its task');
like($errors[1], qr/close of closed/, 'duplicate close is catchable');

sub recursive ($n) {
	my $keep = $n;
	yield;
	return $n ? $keep + recursive($n - 1) : 0;
}
@received = ();
run {
	my $ch = chan;
	act { $ch->send(recursive(9)) };
	act { $ch->send(recursive(12)) };
	push @received, scalar $ch->recv for 1..2;
};
is_deeply([sort {$a <=> $b} @received], [45, 78], 'recursive pads are separate between yielding tasks');

sub counter () { state $count = 0; return ++$count }
@received = ();
run {
	my $ch = chan;
	for (1..4) {
		act { $ch->send(counter()) };
		push @received, scalar $ch->recv;
	}
};
is_deeply(\@received, [1, 2, 3, 4], 'state lexicals retain identity across tasks');

my $saved;
run { $saved = chan(1); $saved->send('left in the buffer') };
my $stale_error;
run { eval { $saved->recv }; $stale_error = $@ };
like($stale_error, qr/inactive run/, 'channel from a previous run is rejected without dereferencing freed memory');

for my $case (
	['act', sub { Wump::_act(sub {}) }],
	['yield', sub { Wump::_yield() }],
	['chan', sub { Wump::_chan(0) }],
	['sleep', sub { Wump::_sleep(0) }],
) {
	eval { $case->[1]->() };
	like($@, qr/running task/, "$case->[0] rejects use outside a run");
}

my @invalid;
run {
	for my $capacity (-1, 0.5, 1e30, 'garbage', undef, []) { eval { chan($capacity) }; push @invalid, $@ }
	eval { run {} }; push @invalid, $@;
};
like($invalid[$_], qr/invalid channel capacity/, 'invalid capacity is rejected') for 0..5;
like($invalid[6], qr/nested runs/, 'nested runs fail without damaging the outer run');

my $deadlock;
eval { run { my $ch = chan; $ch->recv } };
$deadlock = $@;
like($deadlock, qr/runtime failed/, 'deadlock returns an error to the surrounding Perl caller');
run { my $ch = chan(1); $ch->send(99); $copy = $ch->recv };
is($copy, 99, 'runtime recovers after deadlock and abandoned Perl frames');

my $started = 0;
run { act { $started++ } };
is($started, 0, 'returning main abandons a queued task');

my $finished = 0;
run {
	my $ch = chan;
	act { $started++; $ch->recv; $finished++ };
	yield;
};
is($finished, 0, 'returning main abandons a parked Perl task');
is($started, 1, 'parked task had entered Perl before shutdown');

{
	package WumpTest::Tracked;
	sub new ($class, $counter) { bless {counter => $counter}, $class }
	sub DESTROY ($self) { ${$self->{counter}}++ }
}
my $destroyed = 0;
run {
	my $ch = chan;
	act {
		my $owned = WumpTest::Tracked->new(\$destroyed);
		$ch->recv;
	};
	yield;
};
is($destroyed, 1, 'shutdown releases objects owned by an abandoned Perl frame');
run {
	my $owned = WumpTest::Tracked->new(\$destroyed);
	act { die 'unstarted task ran' if $owned };
};
is($destroyed, 2, 'unstarted closure cleanup releases its captured object');
run {
	my $ch = chan(2);
	$ch->send(WumpTest::Tracked->new(\$destroyed));
};
is($destroyed, 3, 'shutdown releases messages left in a buffered channel');

my $stream_sum = 0;
run {
	my $ch = chan(4);
	act { $ch->send($_) for 1..1000; $ch->close };
	while (my ($value, $ok) = $ch->recv) {
		last unless $ok;
		$stream_sum += $value;
	}
};
is($stream_sum, 500500, 'a channel streams repeated sends without retaining received messages');

run {
	my $ch = chan;
	act {
		state $owned = WumpTest::Tracked->new(\$destroyed);
		$ch->send(1);
	};
	$ch->recv;
	yield;
};
is($destroyed, 4, 'cleanup releases state-owned objects without creating new task pad caches');

my @switches = map { "-I$_" } @INC;
open my $panic, '-|', $^X, @switches, '-MWump', '-e', q{
	open STDERR, '>&', STDOUT or die $!;
	eval { Wump::run { my $ch = Wump::chan(); Wump::act { die "child panic\n" }; $ch->recv } };
	print "should not return\n";
} or die "spawn panic test: $!";
my $panic_output = do { local $/; <$panic> };
close $panic;
is($? >> 8, 2, 'uncaught child die terminates the process with status 2');
like($panic_output, qr/task 2 \[panic\]: child panic/, 'panic identifies its task');
unlike($panic_output, qr/should not return/, 'outer eval cannot recover another task panic');

done_testing;
