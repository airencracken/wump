use v5.42;
use strict;
use warnings;
use Test::More;
use B ();
use B::Deparse;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
BEGIN { CLOCK_MONOTONIC() }
use Wump;
use lib 'tests/perl/lib';
use WumpTest qw(check_program);

sub names ($code) {
	my @names;
	my $walk;
	$walk = sub ($op) {
		while ($$op) {
			push @names, $op->name;
			$walk->($op->first) if $op->can('first');
			$op = $op->sibling;
		}
	};
	$walk->(B::svref_2object($code)->ROOT);
	return \@names;
}
my $empty = sub { chan() };
my $buffered = sub { chan(2) };
my $pause = sub { sleep(0) };
for my $case ([$empty, 'wumpchan'], [$buffered, 'wumpchan'], [$pause, 'wumpsleep']) {
	my ($code, $opcode) = @$case;
	ok(grep($_ eq $opcode, @{names($code)}), "$opcode compiles as a native operation");
	ok(!grep($_ eq 'entersub', @{names($code)}), "$opcode bypasses function dispatch");
}
for my $code (sub { Wump::chan(1) }, sub { Wump::sleep(0) }, sub { &chan(1) }, sub { &sleep(0) }) {
	ok(grep($_ eq 'entersub', @{names($code)}), 'qualified and ampersand compatibility calls remain functions');
}
my ($disabled_chan, $disabled_sleep);
{ no Wump; $disabled_chan = sub { chan(1) }; $disabled_sleep = sub { sleep(0) } }
for my $code ($disabled_chan, $disabled_sleep) {
	ok(!grep(/^wump(?:chan|sleep)$/, @{names($code)}), 'lexical opt-out disables intrinsic lowering');
}

my $ch = chan();
isa_ok($ch, 'Wump::Channel', 'default-capacity native channel');
act { $ch->send('unbuffered') };
is($ch->recv, 'unbuffered', 'default native channel performs a rendezvous');
my @values = (17, chan(2), 19);
is(scalar @values, 3, 'native constructor returns one list value');
is_deeply([@values[0,2]], [17,19], 'native constructor preserves adjacent operands');
$ch = $values[1];
$ch->send('one'); $ch->send('two'); $ch->close;
is($ch->recv, 'one', 'native capacity permits the first buffered send');
is($ch->recv, 'two', 'native capacity preserves buffered FIFO order');
is_deeply([$ch->recv], [undef, ''], 'closed native channel drains normally');
is(scalar sleep(0), undef, 'native zero sleep returns scalar undef');
is_deeply([11, (sleep(0)), 13], [11,13], 'native sleep returns empty in list context and preserves operands');
my $started = clock_gettime(CLOCK_MONOTONIC);
sleep(0.001);
cmp_ok(clock_gettime(CLOCK_MONOTONIC) - $started, '>=', 0.0005, 'native timed sleep does not return immediately');

for my $value (undef, -1, 0.5, 'garbage', 'NaN', 'Inf', [], 1e30) {
	my ($native, $qualified);
	eval { chan($value) }; $native = $@;
	eval { Wump::chan($value) }; $qualified = $@;
	like($native, qr/invalid channel capacity/, 'native capacity validation rejects invalid input');
	like($qualified, qr/invalid channel capacity/, 'qualified capacity validation agrees');
}
for my $value (undef, -1, 'garbage', 'NaN', 'Inf', [], 1e30) {
	my ($native, $qualified);
	eval { sleep($value) }; $native = $@;
	eval { Wump::sleep($value) }; $qualified = $@;
	like($native, qr/invalid sleep duration/, 'native duration validation rejects invalid input');
	like($qualified, qr/invalid sleep duration/, 'qualified duration validation agrees');
}

{
	package NativeArg;
	our ($fetches, $value);
	sub TIESCALAR { bless [], shift }
	sub FETCH { $fetches++; my @grow = (1..4096); return $value }
}
tie my $arg, 'NativeArg';
$NativeArg::value = 1;
$NativeArg::fetches = 0;
eval { chan($arg) };
like($@, qr/invalid channel capacity/, 'native constructor preserves rejection of an unfetched tied capacity');
my $native_fetches = $NativeArg::fetches;
$NativeArg::fetches = 0;
eval { Wump::chan($arg) };
like($@, qr/invalid channel capacity/, 'qualified constructor rejects the same tied capacity');
is($NativeArg::fetches, $native_fetches, 'native and qualified constructors retain tied FETCH behavior');
$NativeArg::value = 0;
$NativeArg::fetches = 0;
eval { sleep($arg) };
like($@, qr/invalid sleep duration/, 'native sleep preserves rejection of an unfetched tied duration');
$native_fetches = $NativeArg::fetches;
$NativeArg::fetches = 0;
eval { Wump::sleep($arg) };
like($@, qr/invalid sleep duration/, 'qualified sleep rejects the same tied duration');
is($NativeArg::fetches, $native_fetches, 'native and qualified sleeps retain tied FETCH behavior');
my $grow = sub { my @values = (1..8192); return $_[0] };
my $grown_channel = chan($grow->(1));
$grown_channel->send(42);
is($grown_channel->recv, 42, 'native constructor consumes its argument after operand-stack growth');
is(scalar sleep($grow->(0)), undef, 'native sleep consumes its argument after operand-stack growth');

for my $code ($empty, $buffered, $pause) {
	my $text = B::Deparse->new->coderef2text($code);
	my $copy = eval "use Wump; sub $text";
	is($@, '', 'deparsed native scalar operation compiles again');
	is_deeply([grep(/^wump(?:chan|sleep)$/, @{names($copy)})],
		[grep(/^wump(?:chan|sleep)$/, @{names($code)})], 'deparse retains the native operation');
}
check_program(q{
	use Wump;
	CHECK {
		no warnings qw(redefine prototype);
		*chan = *Wump::chan = *Wump::_chan = sub { die "constructor wrapper entered\n" };
		*sleep = *Wump::sleep = *Wump::_sleep = sub { die "sleep wrapper entered\n" };
	}
	my $ch = chan(1);
	act { sleep(0.001); $ch->send(42) };
	sleep(0);
	die "bad result\n" unless $ch->recv == 42;
	print "native scalar bypass verified\n";
}, 0, qr/native scalar bypass verified/, 'native constructors and sleeps bypass replaced wrappers and XS');
check_program(q{
	BEGIN { $ENV{WUMPPROCS} = 4 }
	use Wump;
	my $out = chan();
	for my $id (1..32) {
		act {
			my $ch = chan(1);
			sleep(0.00001);
			$ch->send($id);
			$out->send(scalar $ch->recv);
		}
	}
	my @ids = sort {$a <=> $b} map {scalar $out->recv} 1..32;
	die "bad completions\n" unless join(',',@ids) eq join(',',1..32);
	print "parallel scalar operations verified\n";
}, 0, qr/parallel scalar operations verified/, 'native creation and timed sleep work on four slots');
for my $case (
	['chan', 'chan(1)'], ['sleep', 'sleep(0)']
) {
	my ($name, $call) = @$case;
	check_program("use Wump; BEGIN { require Opcode; Opcode::opmask_add(Opcode::opset('wump$name')) } $call;",
		255, qr/trapped by operation mask/, "native $name honors opcode masks");
	check_program("use Wump; BEGIN { $call }", 255, qr/requires a running task/,
		"native $name rejects compile-time execution");
}
check_program(q{ use Wump; chan(1,2) }, 255, qr/Too many arguments/, 'native channel keeps prototype arity checks');
check_program(q{ use Wump; sleep() }, 255, qr/Not enough arguments/, 'native sleep keeps prototype arity checks');
check_program(q{
	use Wump;
	BEGIN { require Opcode; Opcode::opmask_add(Opcode::opset('wumpchan')) }
	chan();
}, 255, qr/trapped by operation mask/, 'default-capacity native constructor cleans up its synthesized argument under a mask');
done_testing;
