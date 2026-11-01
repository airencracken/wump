use v5.42;
use strict;
use warnings;
use Test::More;
use B ();
use B::Deparse;
use Scalar::Util 'weaken';
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

my $block = sub { act { 42 } };
my $parenthesized = sub { act(sub { 43 }) };
for my $code ($block, $parenthesized) {
	ok(grep($_ eq 'wumpact', @{names($code)}), 'imported act compiles to a native opcode');
	ok(!grep($_ eq 'entersub', @{names($code)}), 'the creation operation has no wrapper or XS call');
}
my $qualified = sub { Wump::act(sub { 44 }) };
my $indirect = sub { my $fn = \&act; $fn->(sub { 45 }) };
my $ampersand = sub { &act(sub { 46 }) };
my $ordinary;
{ no Wump; $ordinary = sub { act { 47 } } }
for my $code ($qualified, $indirect, $ampersand, $ordinary) {
	ok(grep($_ eq 'entersub', @{names($code)}), 'compatibility call retains ordinary function dispatch');
	ok(!grep($_ eq 'wumpact', @{names($code)}), 'compatibility call is not lowered');
}
my $wrapped = sub { WumpTest::act { 48 } };
ok(!grep($_ eq 'wumpact', @{names($wrapped)}), 'a distinct wrapper CV is not treated as the intrinsic');

check_program(q{
	use Wump;
	CHECK {
		no warnings qw(redefine prototype);
		*act = sub { die "entered imported wrapper\n" };
		*Wump::act = sub { die "entered qualified wrapper\n" };
		*Wump::_act = sub { die "entered XS\n" };
	}
	my $ch = chan();
	act { act { $ch->send(42) } };
	die "bad result\n" unless $ch->recv == 42;
	print "native creation bypass verified\n";
}, 0, qr/native creation bypass verified/, 'compiled native creation bypasses replaced wrapper and XS entries');

my $done = chan();
my $result = scalar act { $done->send(1) };
is($result, undef, 'scalar act returns undef');
is($done->recv, 1, 'scalar-context act runs its closure');
my @values = (11, (act { $done->send(2) }), 13);
is_deeply(\@values, [11, 13], 'list act returns empty and preserves adjacent operands');
is($done->recv, 2, 'list-context act runs its closure');

our $dynamic = 'root';
my $out = chan();
{
	local $dynamic = 'inherited';
	for my $id (1..32) {
		act {
			my $entry_context = wantarray;
			local $_ = "word:$id";
			/([a-z]+):(\d+)/ or die "bad match\n";
			for (1..16) { yield }
			$out->send([$id, $dynamic, $1, 0 + $2,
				!defined($entry_context) ? 'void' : $entry_context ? 'list' : 'scalar']);
		}
	}
}
my @received = sort {$a->[0] <=> $b->[0]} map {scalar $out->recv} 1..32;
is_deeply(\@received, [map {[$_, 'inherited', 'word', $_, 'scalar']} 1..32],
	'native creation retains captures, dynamic snapshots, task match state and existing scalar/discard entry context');
is($dynamic, 'root', 'child snapshots leave the parent scope restored');

my $weak;
{
	my $launch = sub {
		my $owned = bless [], 'NativeActOwned';
		$weak = $owned;
		weaken($weak);
		act { $done->send(ref($owned)) };
	};
	$launch->();
}
is(ref($weak), 'NativeActOwned', 'the queued task owns its captured value');
is($done->recv, 'NativeActOwned', 'the closure remains valid after its creating frame returns');
yield;
ok(!defined($weak), 'completed native task releases its closure capture');

my $text = B::Deparse->new->coderef2text($block);
my $copy = eval "use Wump; sub $text";
is($@, '', 'deparsed native creation compiles again');
ok($copy && grep($_ eq 'wumpact', @{names($copy)}), 'deparse round trip retains native creation');

check_program(q{
	BEGIN { $ENV{WUMPPROCS} = 4 }
	use Wump;
	my $ch = chan();
	for my $id (1..64) {
		act {
			local $_ = "word:$id";
			/([a-z]+):(\d+)/ or die "bad match\n";
			for (1..32) { yield }
			my $value = $2;
			act { $ch->send($value) };
		}
	}
	my @ids = sort {$a <=> $b} map {scalar $ch->recv} 1..64;
	die "bad completions\n" unless join(',', @ids) eq join(',', 1..64);
	print "parallel native creation verified\n";
}, 0, qr/parallel native creation verified/, 'nested native tasks retain captures across four-slot scheduling');
check_program(q{
	use Wump;
	package Owned { sub DESTROY { print "released\n" } }
	sub queue_owned {
		my $object = bless [], 'Owned';
		act { die "queued task ran: $object" };
	}
	queue_owned();
	print "parent returned\n";
}, 0, qr/\Aparent returned\nreleased\n\z/, 'shutdown releases an unstarted native closure exactly once');
check_program(q{
	use Wump;
	BEGIN { act {} }
}, 255, qr/act requires a running task/, 'native creation rejects compile-time execution');
check_program(q{
	use Wump;
	BEGIN { require Opcode; Opcode::opmask_add(Opcode::opset('wumpact')) }
	act { 1 };
}, 255, qr/trapped by operation mask/, 'native creation honors opcode masks');
check_program(q{ use Wump; act() }, 255, qr/Not enough arguments/, 'native creation retains prototype arity checks');
check_program(q{ use Wump; act(sub {}, sub {}) }, 255, qr/Too many arguments/, 'native creation rejects extra arguments');
check_program(q{
	use Wump;
	sub custom :prototype(&) { print "custom wrapper\n" }
	BEGIN { no warnings 'redefine'; *act = \&custom }
	act { die "body must not run" };
}, 0, qr/\Acustom wrapper\n\z/, 'replacing an imported act keeps the custom implementation');
check_program(q{
	use Wump;
	use lib 'tests/perl/lib';
	use WumpTest;
	my $completed = 0;
	with_tasks { act { yield; $completed++ } };
	die "wrapper was bypassed\n" unless $completed == 1;
	print "custom join wrapper verified\n";
}, 0, qr/custom join wrapper verified/, 'custom join wrappers keep their own behavior');
check_program(q{
	use Wump; use B (); use Sub::Util qw(set_subname);
	BEGIN { set_subname('Renamed::act', \&Wump::act) }
	my $code = sub { Wump::act(sub {}) };
	my $op = B::svref_2object($code)->START;
	my %seen;
	while ($$op && !$seen{$$op}++) {
		die "qualified call was lowered\n" if $op->name eq 'wumpact';
		$op = $op->next;
	}
	print "qualified renamed CV verified\n";
}, 0, qr/qualified renamed CV verified/, 'renaming the canonical CV does not lower a qualified compatibility call');
done_testing;
