use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'refaddr';
use Wump;
use lib 'tests/perl/lib';
use WumpTest;

my $counter = {value => 0};
with_tasks {
	my $done = chan;
	for (1..12) {
		act {
			for (1..30) {
				lock $counter;
				my $old = $counter->{value};
				yield;
				$counter->{value} = $old + 1;
			}
			$done->send(1);
		};
	}
	$done->recv for 1..12;
};
is($counter->{value}, 360, 'lock serializes shared reference updates across yields');

my ($error, $after);
with_tasks {
	my $done = chan;
	eval {
		lock $counter;
		act { lock $counter; $done->send('acquired') };
		yield;
		die "unlock on unwind\n";
	};
	$error = $@;
	$after = $done->recv;
};
is($error, "unlock on unwind\n", 'lock keeps exception text intact');
is($after, 'acquired', 'exception unwinding releases a lock to a parked act');

my ($recursive, $returned);
with_tasks {
	lock $counter;
	eval { lock $counter };
	$recursive = $@;
	$returned = refaddr($counter);
};
like($recursive, qr/lock is not reentrant/, 'recursive acquisition fails instead of parking itself');
is($returned, refaddr($counter), 'lock preserves reference identity');

my (@array, %hash, $scalar);
my @events;
with_tasks {
	my $done = chan;
	{
		lock @array;
		lock %hash;
		lock $scalar;
		act {
			my ($a, $h, $s) = (\@array, \%hash, \$scalar);
			{ lock $a; push @events, 'array' }
			{ lock $h; push @events, 'hash' }
			{ lock $s; push @events, 'scalar' }
			$done->send(1);
		};
		yield;
		push @events, 'owner';
	}
	$done->recv;
};
is_deeply(\@events, [qw(owner array hash scalar)], 'aggregate and scalar locks use the same identity as references to them');

my $owned = 0;
{
	package LockOwned;
	sub DESTROY { $owned++ }
}
my @lifetimes;
with_tasks {
	my $item = bless {}, 'LockOwned';
	{ lock $item; undef $item; yield; push @lifetimes, $owned }
	push @lifetimes, $owned;
};
is_deeply(\@lifetimes, [0, 1], 'lock retains its target until scope exit and then releases it immediately');

check_program(q{
	use Wump;
	my $counter = {};
	my $park = chan;
	act { lock $counter; $park->recv };
	yield;
	act { lock $counter; die "canceled waiter ran\n" };
	yield;
	print "main returned\n";
}, 0, qr/\Amain returned\n\z/, 'shutdown cancels lock owner and parked waiter');

check_program(q{
	use Wump;
	my ($a, $b) = ({}, {});
	act { lock $a; yield; lock $b };
	lock $b; yield; lock $a;
}, 2, qr/Wump: runtime failed:/, 'lock-order deadlock terminates with a diagnostic');

done_testing;
