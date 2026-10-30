use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		sub hooked () { my $value = 42; return $value }
		BEGIN { RootFixture::constant_hook(\&hooked) }
		package ActiveNumber {
			use overload '0+' => sub ($self, @rest) {
				my @grow = (1) x 10000;
				Wump::yield(); Wump::yield();
				return $self->[0];
			}, fallback => 1;
		}
		sub exercise ($id) {
			my $original = RootFixture::execution_context();
			local $_ = "act-$id";
			for my $round (1..8) {
				my $value = bless [$id + 100], 'ActiveNumber';
				die "yielding arithmetic lost its result\n" unless $value % 97 == ($id + 100) % 97;
				die "custom ppaddr was bypassed\n" unless hooked() == 42;
				my $sum = 0;
				$sum += $_ % 97 for 1..500;
				die "integer loop lost its state\n" unless $sum == 23400 && $_ eq "act-$id";
				my $zero = 0;
				eval { my $unused = $round % $zero };
				die "native fallback lost its exception\n" unless $@ =~ /Illegal modulus zero/;
				yield;
				my $current = RootFixture::execution_context();
				die "callback changed interpreter or act\n"
					unless $current->[0] == $original->[0] && $current->[1] == $original->[1];
			}
			return $id;
		}
		my $out = chan(16);
		for my $id (1..16) { act { $out->send(exercise($id)) } }
		die "main act lost its state\n" unless exercise(100) == 100;
		my %seen;
		for (1..16) { $seen{$out->recv}++ }
		die "missing or duplicated act\n" unless keys(%seen) == 16 && !grep { $_ != 1 } values %seen;
		die "custom constant hooks did not execute\n" unless RootFixture::constant_hook() == 136;
		print "active dispatch preserves hooks, callbacks, exceptions and private state\n";
	}, 0, qr/\Aactive dispatch preserves hooks, callbacks, exceptions and private state\n\z/,
		"active opcode dispatch retains native behavior on $slots slots");
}

done_testing;
