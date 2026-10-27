use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
use lib 'tests/perl/lib';
use WumpTest ();

my $wg = waitgroup;
isa_ok($wg, 'Wump::WaitGroup', 'functional constructor');
isa_ok(Wump::WaitGroup->new, 'Wump::WaitGroup', 'object constructor');
ok(!defined(&main::wait), 'Perl wait is not replaced by an exported function');
my @empty = await $wg;
is(scalar @empty, 0, 'waiting on an empty group returns immediately without a value');
add $wg, 0;
$wg->wait;
pass('zero increments leave an empty group usable');

my @completed;
for my $id (1..20) {
	add $wg;
	act { yield; push @completed, $id; done $wg };
}
await $wg;
is_deeply([sort {$a <=> $b} @completed], [1..20], 'functional add/done/await wait for registered work');

$wg->add(2);
act { yield; push @completed, 21; $wg->done };
act { push @completed, 22; done $wg };
$wg->wait;
is_deeply([sort {$a <=> $b} @completed], [1..22], 'methods and functions operate on the same counter');

my $ready = chan;
my $out = chan(3);
add $wg;
for my $id (1..3) {
	act { $ready->send(1); $wg->wait; $out->send($id) };
}
$ready->recv for 1..3;
yield;
done $wg;
my @waiters = map { scalar $out->recv } 1..3;
is_deeply([sort {$a <=> $b} @waiters], [1..3], 'completion releases every blocked waiter');

my $returned = chan;
add $wg;
act { $wg->wait; $returned->send(1) };
yield;
done $wg;
eval { add $wg };
like($@, qr/reused before previous waits returned/, 'reuse is rejected while previous waiters are still returning');
$returned->recv;
add $wg;
act { done $wg };
await $wg;
pass('a group can be reused after its previous waits return');

add $wg, 3;
add $wg, -2;
done $wg;
await $wg;
pass('negative deltas can complete several registered operations');
eval { done $wg };
like($@, qr/negative wait group counter/, 'done on an empty group fails explicitly');
add $wg;
eval { add $wg, -2 };
like($@, qr/negative wait group counter/, 'a delta cannot take the counter below zero');
done $wg;
await $wg;
pass('a rejected negative delta leaves the counter unchanged');

my $max = (~0) >> 1;
add $wg, $max;
eval { add $wg };
like($@, qr/counter overflow/, 'integer overflow is rejected before changing the counter');
add $wg, -$max;
await $wg;
pass('the largest supported integer count can be balanced exactly');
add $wg, "$max";
add $wg, "-$max";
await $wg;
pass('integer strings preserve exact values at the signed counter boundary');

for my $delta (undef, [], {}, 0.5, -0.5, 'bad', 'Inf', 'NaN', 1e100) {
	eval { add $wg, $delta };
	like($@, qr/invalid wait group delta/, 'non-integer or out-of-range delta is rejected');
}
add $wg;
done $wg;
await $wg;
pass('invalid arguments leave the group usable');

{
	package GroupDelta;
	sub TIESCALAR ($class, $fetch) { bless {fetch => $fetch}, $class }
	sub FETCH ($self) { $self->{fetch}->() }
}
my $fetches = 0;
tie my $delta, 'GroupDelta', sub { $fetches++; yield; return 1 };
add $wg, $delta;
is($fetches, 1, 'a magical delta is fetched once before counter mutation');
done $wg;
await $wg;
my $victim = waitgroup;
tie my $retiring_delta, 'GroupDelta', sub { $victim->DESTROY; yield; return 1 };
eval { add $victim, $retiring_delta };
like($@, qr/inactive runtime/, 'a yielding FETCH cannot leave a dangling native group pointer');

for my $invalid (undef, 42, [], {}, bless({}, 'Wump::WaitGroup')) {
	eval { await $invalid };
	like($@, qr/invalid wait group/, 'invalid group handles fail without dereferencing native memory');
}
eval { $$wg = 42 };
like($@, qr/read-only/, 'the native identity cannot be overwritten');
eval { Wump::_wg_add($wg) };
like($@, qr/Usage:/, 'the native bridge checks arity');
eval { $wg->add(1, 2) };
like($@, qr/Usage:/, 'method invocation checks arity as well');

my $retired;
{
	my $temporary = waitgroup;
	$retired = $$temporary;
}
my $stale = bless \$retired, 'Wump::WaitGroup';
eval { await $stale };
like($@, qr/inactive runtime/, 'dropping the final reference retires the native handle');

my $finishing = waitgroup;
my $finishing_id = $$finishing;
my $finished = chan;
add $finishing;
act { await $finishing; $finished->send(1) };
yield;
done $finishing;
undef $finishing;
$finished->recv;
my $finished_handle = bless \$finishing_id, 'Wump::WaitGroup';
eval { await $finished_handle };
like($@, qr/inactive runtime/, 'a group dropped during wait is retired after its final waiter returns');

for (1..100) {
	my $reused = waitgroup;
	for (1..3) { add $reused; act { yield; done $reused }; await $reused }
}
pass('repeated construction and reuse release notification resources');

WumpTest::check_program(q{
	use Wump;
	my $wg = waitgroup;
	my @seen;
	add $wg;
	act {
		add $wg;
		act { sleep 0.001; push @seen, 'grandchild'; done $wg };
		push @seen, 'parent';
		done $wg;
	};
	await $wg;
	print join(',', sort @seen), "\n";
}, 0, qr/\Agrandchild,parent\n\z/, 'descendants participate only through explicit registration');

WumpTest::check_program(q{
	use Wump;
	my $wg = waitgroup;
	my $park = chan;
	act { $park->recv; print "unregistered finished\n" };
	add $wg;
	act { done $wg };
	await $wg;
	print "registered finished\n";
}, 0, qr/\Aregistered finished\n\z/, 'await ignores acts that were not registered');

WumpTest::check_program(q{
	use Wump;
	my $wg = waitgroup;
	add $wg;
	act { $wg->wait; print "waiter resumed\n" };
	yield;
	print "main returned\n";
}, 0, qr/\Amain returned\n\z/, 'main exit cleans up parked waiters without joining them');

WumpTest::check_program(q{
	use Wump;
	my $wg = waitgroup;
	add $wg;
	await $wg;
}, 2, qr/Wump: runtime failed:/, 'missing completion reports a runtime deadlock');

WumpTest::check_program(q{
	use Wump::WaitGroup;
	my $wg = Wump::WaitGroup->new;
	$wg->add;
	Wump::act { $wg->done };
	$wg->wait;
	print "object only\n";
}, 0, qr/\Aobject only\n\z/, 'the object module enables the runtime without exporting functions');

is(CORE::wait(), -1, 'the existing process wait keyword retains its behavior');
done_testing;
