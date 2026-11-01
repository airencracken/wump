use v5.42;
use strict;
use warnings;
use Test::More;
use B ();
use B::Deparse;
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

my $native = sub { yield };
my $parenthesized = sub { yield() };
my $qualified = sub { Wump::yield() };
for my $code ($native, $parenthesized) {
	my $names = names($code);
	ok(grep($_ eq 'wumpyield', @$names), 'bare yield compiles to a native opcode');
	ok(!grep($_ eq 'entersub', @$names), 'native yield has no Perl or XS call operation');
}
ok(grep($_ eq 'entersub', @{names($qualified)}), 'qualified compatibility call retains normal function lookup');
check_program(q{
	use Wump;
	BEGIN {
		no warnings 'redefine';
		*Wump::yield = sub () { die "entered Perl wrapper\n" };
		*Wump::_yield = sub { die "entered XS\n" };
	}
	yield; yield(); print "native bypass verified\n";
}, 0, qr/native bypass verified/, 'native yield bypasses both wrapper and XS');
is(scalar $native->(), undef, 'scalar yield returns undef');
is_deeply([$native->()], [], 'list yield returns an empty list');
is_deeply([17, yield, 19], [17, 19], 'native yield preserves surrounding operand stack entries');

our $dynamic = 'root';
sub nested ($id) {
	local $dynamic = "child:$id";
	local $_ = "word:$id";
	/([a-z]+):(\d+)/ or die "match failed\n";
	my $caller = (caller(0))[3];
	for (1..128) {
		yield;
		die "context changed\n" unless $dynamic eq "child:$id" && $1 eq 'word' && $2 == $id
			&& (caller(0))[3] eq $caller;
	}
	return $id;
}
my $out = chan();
for my $id (1..32) { act { $out->send(nested($id)) } }
my @ids = sort {$a <=> $b} map {scalar $out->recv} 1..32;
is_deeply(\@ids, [1..32], 'nested native yields preserve task state through interleaving and migration');
is($dynamic, 'root', 'native child yields leave parent dynamic state intact');
{
	check_program(q{
		BEGIN { $ENV{WUMPPROCS} = 4 }
		use Wump;
		my $out = chan();
		for my $id (1..32) {
			act {
				local $_ = "word:$id";
				/([a-z]+):(\d+)/ or die "match failed\n";
				for (1..128) {
					yield();
					die "task state changed\n" unless $1 eq 'word' && $2 == $id;
				}
				$out->send($id);
			}
		}
		my @ids = sort {$a <=> $b} map {scalar $out->recv} 1..32;
		die "bad completions\n" unless join(',', @ids) eq join(',', 1..32);
		print "parallel native yields verified\n";
	}, 0, qr/parallel native yields verified/, 'native yield preserves task state on four slots');
}

my $ordinary;
{
	no Wump;
	$ordinary = sub { yield() };
}
ok(grep($_ eq 'entersub', @{names($ordinary)}), 'no Wump restores ordinary function compilation');
my $keys = {yield => 'value'};
is($keys->{yield}, 'value', 'yield remains an implicitly quoted hash key');
{ package YieldName; sub yield { 'method' } }
is(YieldName->yield, 'method', 'method names bypass lexical keyword lookup');
my $text = B::Deparse->new->coderef2text($native);
like($text, qr/\byield\b/, 'deparse retains the native keyword');
my $copy = eval "use Wump; sub $text";
is($@, '', 'deparsed native yield compiles again');
ok($copy && grep($_ eq 'wumpyield', @{names($copy)}), 'deparse round trip retains the native opcode');
check_program(q{use Wump; BEGIN { yield }}, 255, qr/yield requires a running task/,
	'native yield rejects compile-time scheduling without a task');
check_program(q{use Wump; yield(1)}, 255, qr/syntax error|Too many arguments/,
	'native yield rejects arguments');
check_program(q{
	sub yield { print "ordinary function\n" }
	yield();
}, 0, qr/ordinary function/, 'programs without Wump retain their yield function');
check_program(q{
	use Opcode qw(opset opset_to_ops);
	die "missing thread classification\n" unless grep {$_ eq 'wumpyield'} opset_to_ops(opset(':base_thread'));
	print "native scheduling policy verified\n";
}, 0, qr/native scheduling policy verified/, 'Opcode classifies native yield with thread operations');
check_program(q{
	use Wump;
	BEGIN { require Opcode; Opcode::opmask_add(Opcode::opset('wumpyield')) }
	yield;
}, 255, qr/trapped by operation mask/, 'native yield respects Opcode compilation masks');
done_testing;
