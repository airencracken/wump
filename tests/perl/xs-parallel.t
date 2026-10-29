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
		use Wump; use File::Spec::Unix (); use RootFixture;
		my @cases = (["a/./b//", "a/b"], ["/../../a", "/a"], ["./", "."],
			["", ""], [undef, undef], [123, "123"], ["\x{100}/./b", "\x{100}/b"],
			["a\0b/./c", "a\0b/c"]);
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					for my $case (@cases) {
						my $expected = $case->[1];
						for my $actual (File::Spec::Unix::_fn_canonpath($case->[0]),
							File::Spec::Unix->canonpath($case->[0])) {
							die "canonical path changed\n" if defined($expected)
								? !defined($actual) || $actual ne $expected : defined($actual);
						}
					}
					yield;
				}
				$out->send(1);
			};
		}
		die "missing path workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			{ package TiedPath; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "native path called FETCH\n" } }
			tie my $path, 'TiedPath';
			eval { File::Spec::Unix::_fn_canonpath($path) };
			die "magical path admitted: $@" unless $@ =~ /requires a plain scalar/;
			eval { File::Spec::Unix::_fn_canonpath([]) };
			die "reference path admitted: $@" unless $@ =~ /requires a plain scalar/;
		}
		print "native path normalization retained scalar semantics\n";
	}, 0, qr/\Anative path normalization retained scalar semantics\n\z/,
		"audited path normalization runs on $slots slots with boundary input coverage");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use Cwd (); use RootFixture;
		our $expected;
		BEGIN { $expected = Cwd::getcwd() }
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..64) {
					die "cwd changed\n" unless Cwd::getcwd() eq $expected;
					die "fast cwd changed\n" unless Cwd::fastcwd() eq $expected;
					yield;
				}
				$out->send(1);
			};
		}
		die "missing cwd workers\n" if grep { $out->recv != 1 } 1..8;
		eval { Cwd::fastcwd(1) };
		die "cwd alias accepted arguments\n" unless $@ =~ /Usage:/;
		print "native cwd readers retained independent results\n";
	}, 0, qr/\Anative cwd readers retained independent results\n\z/,
		"audited cwd readers run on $slots slots and retain alias argument validation");
}

{
	local $ENV{WUMPPROCS} = 4;
	WumpTest::check_program(q{
		use Wump; use Cwd (); use File::Temp ();
		our $original;
		BEGIN {
			$original = Cwd::getcwd();
			my $gone = File::Temp::tempdir(TMPDIR => 1);
			chdir $gone or die "chdir: $!";
			rmdir $gone or die "rmdir: $!";
		}
		die "deleted cwd did not fail\n" if defined Cwd::getcwd();
		# Only the main act is running; restore the process directory before
		# starting any workers or loading more files.
		chdir $original or die "restore cwd: $!";
		die "cwd did not recover\n" unless Cwd::getcwd() eq $original;
		eval { Cwd::abs_path('.') };
		die "unaudited cwd helper admitted: $@" unless $@ =~ /XS function has not declared parallel safety: Cwd::abs_path/;
		print "cwd failure recovered and other native path helpers stayed gated\n";
	}, 0, qr/\Acwd failure recovered and other native path helpers stayed gated\n\z/,
		'cwd readers preserve failure/recovery behavior without admitting unrelated helpers');
}

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
