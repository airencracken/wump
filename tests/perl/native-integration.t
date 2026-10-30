use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use List::Util qw(min max);
		use Scalar::Util qw(dualvar looks_like_number);
		{ package AncestryRoot; sub DESTROY {} }
		{ package AncestryChild; our @ISA; BEGIN { @ISA = ('AncestryRoot') } }
		sub same_heads {
			my $original = shift;
			for (@_) { die "repeat lost source aliases\n" unless \$_ == $original }
		}
		our (@values, @numbers, @expected, @arithmetic, $object, $latin);
		BEGIN {
			@values = (dualvar(7, 'seven'), -2, 42, 42, 0.5);
			@numbers = (undef, '', 'abc', '12', '-3.5', '1e9', 'Inf', 'NaN', 123);
			@expected = map { !!looks_like_number($_) } @numbers;
			$object = bless {}, 'AncestryChild';
			$latin = "Caf\x{e9}"; utf8::upgrade($latin);
			@arithmetic = map { [@$_, $_->[0] + $_->[1], $_->[0] % $_->[1]] }
				([0, 1], [-42, 5], [42, -5], [9223372036854775807, 2], [1 << 63, 3], [1.25, 2]);
		}
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					same_heads(\$values[0], ($values[0]) x 32);
					for my $case (@arithmetic) {
						die "addition boundary changed\n" unless $case->[0] + $case->[1] == $case->[2];
						die "modulo boundary changed\n" unless $case->[0] % $case->[1] == $case->[3];
					}
					eval { my $zero = 0; my $value = 42 % $zero };
					die "zero divisor diagnostic changed: $@" unless $@ =~ /Illegal modulus zero/;
					die "min alias changed\n" unless \min(@values) == \$values[1];
					die "max tie alias changed\n" unless \max(@values) == \$values[3];
					die "dualvar changed\n" unless min($values[0]) eq 'seven';
					die "empty min changed\n" if defined min();
					for my $i (0..$#numbers) {
						die "numeric classification changed\n" unless !!looks_like_number($numbers[$i]) == $expected[$i];
					}
					die "class ancestry changed\n" unless UNIVERSAL::isa('AncestryChild', 'AncestryRoot');
					die "object ancestry changed\n" unless $object->isa('AncestryRoot') && $object->isa('HASH');
					die "negative ancestry changed\n" if $object->isa('MissingAncestor') || UNIVERSAL::isa(undef, 'AncestryRoot');
					my $bytes = $latin;
					my $alias = \$bytes;
					$bytes =~ /Caf/g;
					die "byte downgrade failed\n" unless utf8::downgrade($bytes) && $$alias eq "Caf\x{e9}" && !utf8::is_utf8($bytes);
					my $wide = "\x{100}";
					die "failok downgrade changed wide source\n" if utf8::downgrade($wide, 1) || $wide ne "\x{100}";
					eval { utf8::downgrade($wide) };
					die "wide downgrade failed silently: $@" unless $@ =~ /Wide character/;
					yield;
				}
				$out->send(1);
			};
		}
		die "missing native workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			{ package NativeTie; sub TIESCALAR { bless {}, shift } sub FETCH { die "native FETCH ran\n" } }
			tie my $bad, 'NativeTie';
			for my $call (sub { min($bad, 2) }, sub { looks_like_number($bad) },
				sub { utf8::downgrade($bad) }, sub { UNIVERSAL::isa($bad, 'AncestryRoot') }) {
				eval { $call->() };
				die "native magic admitted: $@" unless $@ =~ /plain scalar/;
			}
		}
		print "native selection, ancestry and byte mutations preserve aliases and recovery\n";
	}, 0, qr/\Anative selection, ancestry and byte mutations preserve aliases and recovery\n\z/,
		"native integration contracts on $slots slots");

	WumpTest::check_program(q{
		use Wump; use IO::Poll qw(POLLIN); use IO::Handle;
		our ($reader, $writer, $fd);
		BEGIN { pipe($reader, $writer) or die $!; $fd = fileno($reader); syswrite($writer, 'x') == 1 or die $! }
		my $events = POLLIN;
		my $original_fd = $fd;
		die "ready poll failed\n" unless IO::Poll::_poll(0, $fd, $events) == 1 && ($events & POLLIN) && $fd == $original_fd;
		die "nonblocking mode failed\n" unless defined $reader->blocking(0);
		die "mode query changed\n" unless $reader->blocking == 0;
		die "empty poll failed\n" unless IO::Poll::_poll(0) == 0;
		if (Wump::execution_slots() > 1) {
			for my $invalid (1, -1, 0.5, 'bad', undef, 1e30) {
				eval { IO::Poll::_poll($invalid) };
				die "blocking or malformed poll admitted: $@" unless $@ =~ /zero timeout|integer arguments/;
			}
			eval { IO::Poll::_poll(0, $fd) };
			die "odd poll args admitted: $@" unless $@ =~ /descriptor\/event pairs/;
			eval { IO::Poll::_poll(0, $fd, POLLIN) };
			die "readonly writeback admitted: $@" unless $@ =~ /read-only/;
			eval { $reader->blocking(1) };
			die "blocking mode admitted: $@" unless $@ =~ /only supports queries or nonblocking/;
			{ package PollTie; sub TIESCALAR { bless {}, shift } sub FETCH { die "poll FETCH ran\n" } }
			tie my $bad, 'PollTie';
			eval { IO::Poll::_poll($bad) };
			die "magical timeout admitted: $@" unless $@ =~ /plain scalar/;
			eval { $reader->blocking($bad) };
			die "magical mode admitted: $@" unless $@ =~ /plain scalar/;
		}
		$events = POLLIN;
		die "poll failed after rejected calls\n" unless IO::Poll::_poll(0, $fd, $events) == 1;
		close $reader; close $writer;
		print "poll preserves in-out aliases and rejects blocking native operations\n";
	}, 0, qr/\Apoll preserves in-out aliases and rejects blocking native operations\n\z/,
		"reactor native contracts on $slots slots");
}
done_testing;
