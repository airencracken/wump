use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

WumpTest::check_program(q{
	use Wump ();
	BEGIN {
		eval { Wump::execution_slots() };
		die "compile-time slot query admitted: $@" unless $@ =~ /requires a running act/;
	}
	print "slot query requires an act\n";
}, 0, qr/\Aslot query requires an act\n\z/, 'slot reporting rejects calls before scheduler startup');

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump;
		use Time::HiRes ();
		use RootFixture;
		BEGIN { Time::HiRes::CLOCK_MONOTONIC() }
		my $clock = Time::HiRes::CLOCK_MONOTONIC();
		my $slots = Wump::execution_slots();
		die "wrong execution slots\n" unless $slots == $ENV{WUMPPROCS};
		eval { Wump::execution_slots(1) };
		die "slot query accepted arguments: $@" unless $@ =~ /no arguments/;
		# No workers have started yet. Change the process setting explicitly;
		# localizing ENV elements inside an act is outside the current bridge.
		my $configured = $ENV{WUMPPROCS};
		$ENV{WUMPPROCS} = 255;
		die "slot report used environment\n" unless Wump::execution_slots() == $slots;
		$ENV{WUMPPROCS} = $configured;
		my $out = chan(4);
		my $group = waitgroup;
		for (1..8) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				die "child slot report changed\n" unless Wump::execution_slots() == $slots;
				for (1..64) {
					my $before = Time::HiRes::clock_gettime($clock);
					my $wall = Time::HiRes::time();
					my ($seconds, $micros) = Time::HiRes::gettimeofday();
					die "invalid wall clock\n" unless $wall > 0 && $seconds > 0
						&& $micros >= 0 && $micros < 1_000_000;
					die "invalid clock resolution\n" unless Time::HiRes::clock_getres($clock) > 0;
					yield;
					die "monotonic clock reversed\n" unless Time::HiRes::clock_gettime($clock) >= $before;
				}
				$out->send(1);
				done $group;
			};
		}
		for (1..8) { die "missing clock workers\n" unless $out->recv == 1 }
		await $group;
		die "invalid clock ID changed behavior\n" unless Time::HiRes::clock_gettime(-12345) == -1;
		print "audited clocks completed on every slot\n";
	}, 0, qr/\Aaudited clocks completed on every slot\n\z/,
		"audited native clocks run with $slots slots and survive migration");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump;
		use Unicode::Normalize qw(NFC NFD NFKC NFKD FCC);
		use RootFixture;
		my @cases = (
			["Cafe\x{301}", "Caf\x{e9}"], ["Caf\x{e9}", "Caf\x{e9}"],
			["A\0e\x{301}", "A\0\x{e9}"], ["\x{1100}\x{1161}", "\x{ac00}"],
			['', ''], [123, '123'],
		);
		my $out = chan(4);
		my $group = waitgroup;
		for (1..8) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					for my $case (@cases) {
						my $expected = $case->[1];
						die "wrong NFC result\n" unless NFC($case->[0]) eq $expected;
						die "wrong NFD round trip\n" unless NFC(NFD($case->[0])) eq $expected;
					}
					die "wrong compatibility composition\n" unless NFKC("\x{fb03}") eq 'ffi';
					die "wrong compatibility decomposition\n" unless NFKD("\x{fb03}") eq 'ffi';
					die "wrong contiguous composition\n" unless FCC("e\x{301}") eq "\x{e9}";
					yield;
				}
				$out->send(1);
				done $group;
			};
		}
		for (1..8) { die "missing Unicode worker\n" unless $out->recv == 1 }
		await $group;
		die "normalization changed shared input\n" unless $cases[0][0] eq "Cafe\x{301}";
		print "shared Unicode inputs normalized without modification\n";
	}, 0, qr/\Ashared Unicode inputs normalized without modification\n\z/,
		"audited Unicode normalization runs on $slots slots with shared inputs");
}

{
	local $ENV{WUMPPROCS} = 4;
	WumpTest::check_program(q{
		use Wump;
		use Time::HiRes ();
		for my $call (\&Time::HiRes::usleep, \&Time::HiRes::alarm) {
			eval { $call->(0) };
			die "unaudited XS admitted: $@" unless $@ =~ /XS function has not declared parallel safety: Time::HiRes::(?:usleep|alarm)/;
		}
		print "blocking calls and process timers remain rejected\n";
	}, 0, qr/\Ablocking calls and process timers remain rejected\n\z/,
		'clock registration does not admit the rest of Time::HiRes and identifies rejected entries');
	WumpTest::check_program(q{
		use Wump;
		use Unicode::Normalize qw(NFC compose);
		use RootFixture;
		our $bad;
		BEGIN { $bad = RootFixture::malformed_utf8() }
		package NormalizeTie {
			sub TIESCALAR { bless {}, shift }
			sub FETCH { die "unexpected normalization FETCH\n" }
		}
		tie my $magical, 'NormalizeTie';
		eval { NFC($magical) };
		die "magical input admitted: $@" unless $@ =~ /requires a plain scalar/;
		eval { NFC($bad) };
		die "malformed input admitted: $@" unless $@ =~ /requires well-formed UTF-8/;
		eval { NFC([]) };
		die "reference input admitted: $@" unless $@ =~ /requires a plain scalar/;
		eval { compose('text') };
		die "unaudited normalizer admitted: $@" unless $@ =~ /XS function has not declared parallel safety: Unicode::Normalize::compose/;
		die "normalizer failed after rejection\n" unless NFC("e\x{301}") eq "\x{e9}";
		print "invalid normalization inputs and unaudited entries rejected\n";
	}, 0, qr/\Ainvalid normalization inputs and unaudited entries rejected\n\z/,
		'normalization rejects unsupported inputs before allocating native buffers and recovers');
}

done_testing;
