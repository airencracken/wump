use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

sub quiescent ($label) {
	my $stats = RootFixture::memory_stats();
	is($stats->[0], 0, "$label releases lifetime pins");
	is($stats->[1], 0, "$label drains retired storage");
}

my $value = 'original cached string with enough room to exercise replacement';
RootFixture::scalar_publish(\$value);
my $old = $value;
my $answer = RootFixture::memory_borrow(\$value, 0, sub {
	my $ready = chan;
	act { RootFixture::memory_replace(\$value, 'new'); $ready->send(1) };
	$ready->recv;
	my $stats = RootFixture::memory_stats();
	ok($stats->[0] > 0, 'a parked C borrower retains its pin');
	ok($stats->[1] > 0, 'replacement retires the old scalar storage');
});
is($answer, $old, 'a cached string survives a yield and replacement by another act');
is($value, 'new', 'the live scalar contains the replacement');
quiescent('scalar borrow');

for my $kind (0, 1, 3) {
	my @array = ('old array', 'second');
	RootFixture::scalar_publish(\@array);
	my $result = RootFixture::memory_borrow(\@array, 1, sub {
		yield;
		RootFixture::memory_container(\@array, $kind);
	});
	is($result, 'old array', "array slot survives storage mutation $kind");
	quiescent("array mutation $kind");
}

for my $kind (2, 4) {
	my %hash = (key => 'old hash', other => 'another');
	RootFixture::scalar_publish(\%hash);
	my $result = RootFixture::memory_borrow(\%hash, 2, sub {
		yield;
		RootFixture::memory_container(\%hash, $kind);
	});
	is($result, 'old hash', "hash entry survives deletion/storage mutation $kind");
	quiescent("hash mutation $kind");
}

my @nested = ('nested array');
RootFixture::scalar_publish(\@nested);
my $nested_result = RootFixture::memory_borrow(\$value, 0, sub {
	my $inner = RootFixture::memory_borrow(\@nested, 1, sub {
		RootFixture::memory_replace(\$value, 'nested replacement');
		RootFixture::memory_container(\@nested, 3);
	});
	is($inner, 'nested array', 'nested borrows retain their own storage');
});
is($nested_result, 'new', 'an outer borrow remains valid after nested reclamation');
quiescent('nested borrow');

eval {
	RootFixture::memory_borrow(\$value, 0, sub {
		RootFixture::memory_replace(\$value, 'after throw');
		die "borrow callback failed\n";
	});
};
like($@, qr/borrow callback failed/, 'borrow callback exceptions propagate');
quiescent('throwing borrow');

eval { RootFixture::memory_guard(\$value, sub { die "guard callback failed\n" }) };
like($@, qr/guard callback failed/, 'mutation guard exceptions propagate');
RootFixture::memory_replace(\$value, 'guard released');
is($value, 'guard released', 'an exception releases the mutation claim');
RootFixture::memory_guard(\$value, sub { RootFixture::memory_replace(\$value, 'nested guard') });
is($value, 'nested guard', 'the owning act can nest mutation APIs');
quiescent('mutation guards');

my ($ready, $attempted, $release) = (chan, chan, chan);
my $group = waitgroup;
add $group;
act {
	RootFixture::memory_guard(\$value, sub {
		$ready->send(1);
		$release->recv;
	});
	done $group;
};
$ready->recv;
eval { RootFixture::memory_replace(\$value, 'conflicting write') };
like($@, qr/concurrent mutation/, 'a different act cannot enter an active mutation');
eval { RootFixture::scalar_publish(\$value) };
like($@, qr/publication overlaps mutation/, 'publication rejects a value actively mutated by another act');
$release->send(1);
await $group;
is($value, 'nested guard', 'the rejected writer leaves the value unchanged');
RootFixture::memory_replace(\$value, 'next write');
is($value, 'next write', 'mutation continues after the parked owner releases');
quiescent('conflicting write');

my @guarded_array = ('guarded element');
RootFixture::scalar_publish(\@guarded_array);
eval {
	RootFixture::memory_guard(\@guarded_array, sub {
		RootFixture::memory_borrow(\@guarded_array, 1, sub {});
	});
};
like($@, qr/cannot borrow array storage inside its mutation/, 'a writer cannot export mutable array storage');
quiescent('rejected mutable borrow');

{
	package RetiredObject;
	our $destroyed = 0;
	sub DESTROY { $destroyed++ }
}
my @objects = (bless({}, 'RetiredObject'));
RootFixture::scalar_publish(\@objects);
RootFixture::memory_borrow(\@objects, 1, sub {
	RootFixture::memory_container(\@objects, 3);
	is($RetiredObject::destroyed, 0, 'a retired array keeps removed objects alive for its borrower');
});
is($RetiredObject::destroyed, 1, 'reclamation destroys a removed object exactly once');
quiescent('retired object');

my $store_hook;
{
	package GuardedTie;
	sub TIESCALAR { bless {value => 'initial'}, $_[0] }
	sub FETCH { $_[0]{value} }
	sub STORE { $store_hook->() if $store_hook; $_[0]{value} = $_[1] }
}
tie my $tied, 'GuardedTie';
RootFixture::scalar_publish(\$tied);
my ($begin_magic, $end_magic) = (chan, chan);
my $magic_group = waitgroup;
add $magic_group;
act {
	$begin_magic->recv;
	eval { RootFixture::memory_replace(\$tied, 'conflicting magic write', 1) };
	$end_magic->send($@);
	done $magic_group;
};
my $magic_error;
$store_hook = sub {
	$begin_magic->send(1);
	$magic_error = $end_magic->recv;
};
RootFixture::memory_replace(\$tied, 'accepted magic write', 1);
$store_hook = undef;
await $magic_group;
like($magic_error, qr/concurrent mutation/, 'a C mutation guard remains held across a yielding STORE hook');
is($tied, 'accepted magic write', 'the rejected writer cannot replace the tied value');
quiescent('yielding STORE');

WumpTest::check_program(q{
	use Wump; use RootFixture;
	my $value = 'parked source';
	my ($ready, $park) = (chan, chan);
	act {
		RootFixture::memory_borrow(\$value, 0, sub {
			RootFixture::memory_replace(\$value, 'retired source');
			$ready->send(1);
			$park->recv;
		});
	};
	$ready->recv;
	print "borrow parked\n";
}, 0, qr/\Aborrow parked\n\z/, 'abandoned C borrowers release their pins and retired storage');

WumpTest::check_program(q{
	use Wump; use RootFixture;
	my $value = 'guarded source';
	my ($ready, $park) = (chan, chan);
	act { RootFixture::memory_guard(\$value, sub { $ready->send(1); $park->recv }) };
	$ready->recv;
	print "guard parked\n";
}, 0, qr/\Aguard parked\n\z/, 'abandoned C writers release mutation claims');
done_testing;
