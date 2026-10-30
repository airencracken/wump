use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

WumpTest::check_program(q{
	use RootFixture;
	sub sum ($limit) { my $total = 0; $total += $_ % 97 for 1..$limit; return $total }
	sub hooked () { my $value = 42; return $value }
	RootFixture::constant_hook(\&hooked);
	die "ordinary dispatch bypassed custom ppaddr\n" unless hooked() == 42 && RootFixture::constant_hook() == 1;
	die "cold root changed\n" unless sum(1000) == 47025;
	{ package TransitionNumber;
		use overload '0+' => sub {
			my @grow = (1) x 20000;
			RootFixture::activate_and_clear();
			return 100;
		}, fallback => 1;
	}
	my $value = bless {}, 'TransitionNumber';
	die "transition changed modulus\n" unless $value % 97 == 3;
	die "transition leaked an act\n" if RootFixture::execution_context()->[1];
	die "warm root changed\n" unless sum(1000) == 47025;
	die "warm dispatch bypassed custom ppaddr\n" unless hooked() == 42 && RootFixture::constant_hook() == 2;
	my $text = 'original';
	{ local $_ = 'outer'; for ('a', 'b') { $text .= $_ } die "iterator scope changed\n" unless $_ eq 'outer' }
	die "root scalar changed\n" unless $text eq 'originalab';
	print "native opcode callbacks preserve the root across first context activation\n";
}, 0, qr/\Anative opcode callbacks preserve the root across first context activation\n\z/,
	'ordinary opcode frames survive stack growth and context activation in coercion');

WumpTest::check_program(q{
	use RootFixture;
	sub modulo ($left, $right) { return $left % $right }
	my @cases = (
		[100, 97, 3],
		[18446744073709551614, 18446744073709551615, 18446744073709551614],
		[-100, 97, 94], [100, -97, -94], [-100, -97, -3],
		[1e30, 16, 0], [100, 97, 3],
	);
	for my $case (@cases) {
		die "ordinary numeric representation changed\n" unless modulo(@$case[0, 1]) == $case->[2];
	}
	{ package RetiredNumber;
		use overload '0+' => sub { 100 }, fallback => 1;
		sub DESTROY { RootFixture::activate_and_clear(); $main::drops++ }
	}
	our $drops = 0;
	my $value = bless {}, 'RetiredNumber';
	$value += 2;
	die "numeric replacement lost its destructor\n" unless $drops == 1 && $value == 102;
	die "numeric destructor leaked an act\n" if RootFixture::execution_context()->[1];
	die "numeric replacement lost its root\n" unless modulo(100, 97) == 3;
	print "ordinary numeric setters retain representation and destructor behavior\n";
}, 0, qr/\Aordinary numeric setters retain representation and destructor behavior\n\z/,
	'ordinary numeric targets cross IV, UV and NV boundaries and retain destructor reentry');

WumpTest::check_program(q{
	use RootFixture;
	{ package ThrowingNumber;
		use overload '0+' => sub { RootFixture::activate_and_clear(); die "coercion failed\n" }, fallback => 1;
	}
	my $value = bless {}, 'ThrowingNumber';
	eval { my $ignored = $value % 97 };
	die "transition lost exception: $@" unless $@ eq "coercion failed\n";
	die "exception leaked an act\n" if RootFixture::execution_context()->[1];
	my $sum = 0; $sum += $_ for 1..100;
	die "root recovery failed\n" unless $sum == 5050;
	print "ordinary opcode exceptions unwind after context activation\n";
}, 0, qr/\Aordinary opcode exceptions unwind after context activation\n\z/,
	'ordinary opcode unwind retains native exception and root state');

done_testing;
