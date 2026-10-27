use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
use lib 'tests/perl/lib';
use WumpTest;
no warnings 'experimental::args_array_with_signatures';

my @received;
scope {
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
scope {
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
scope {
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
scope {
	my $ch = chan;
	act { $ch->send(recursive(9)) };
	act { $ch->send(recursive(12)) };
	push @received, scalar $ch->recv for 1..2;
};
is_deeply([sort {$a <=> $b} @received], [45, 78], 'recursive pads are separate between yielding tasks');

sub counter () { state $count = 0; return ++$count }
@received = ();
scope {
	my $ch = chan;
	for (1..4) {
		act { $ch->send(counter()) };
		push @received, scalar $ch->recv;
	}
};
is_deeply(\@received, [1, 2, 3, 4], 'state lexicals retain identity across tasks');

my @invalid;
scope {
	for my $capacity (-1, 0.5, 1e30, 'garbage', undef, []) { eval { chan($capacity) }; push @invalid, $@ }
};
like($invalid[$_], qr/invalid channel capacity/, 'invalid capacity is rejected') for 0..5;

my $stream_sum = 0;
scope {
	my $ch = chan(4);
	act { $ch->send($_) for 1..1000; $ch->close };
	while (my ($value, $ok) = $ch->recv) {
		last unless $ok;
		$stream_sum += $value;
	}
};
is($stream_sum, 500500, 'a channel streams repeated sends without retaining received messages');

check_program(q{
	use Wump;
	package Tracked { sub DESTROY { print "released\n" } }
	my $ch = chan(1);
	$ch->send(bless {}, 'Tracked');
	act { die 'queued act ran' };
}, 0, qr/\Areleased\n\z/, 'shutdown releases buffered messages and abandons queued work');

check_program(q{
	use Wump;
	package Tracked { sub DESTROY { print "released\n" } }
	scope { act { state $owned = bless {}, 'Tracked' } };
	print "completed\n";
}, 0, qr/\Areleased\ncompleted\n\z/, 'completion releases state-owned values');

done_testing;
