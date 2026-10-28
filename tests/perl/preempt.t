use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $setup ('', 'use RootFixture; BEGIN { RootFixture::debug_runops() }') {
	my $loop = $setup ? 'debug' : 'standard';
	WumpTest::check_program($setup . q{
	use Wump;
	alarm 3;
	my ($started, $stop) = (0, 0);
	my $wg = waitgroup;
	add $wg;
	act { $started = 1; 1 until $stop; done $wg };
	1 until $started;
	$stop = 1;
	await $wg;
	print "both compute loops progressed\n";
	}, 0, qr/\Aboth compute loops progressed\n\z/,
		"$loop runloop shares one slot between tight loops without explicit yields");

	WumpTest::check_program($setup . q{
	use Wump;
	alarm 3;
	my $stop = 0;
	act { sleep 0.02; $stop = 1 };
	1 until $stop;
	print "timer progressed\n";
	}, 0, qr/\Atimer progressed\n\z/, "$loop runloop advances timers while main computes");
}

WumpTest::check_program(q{
	use Wump;
	alarm 3;
	my @started;
	my $wg = waitgroup;
	our $value = 'root';
	for my $id (0..7) {
		add $wg;
		act {
			local $value = "act$id";
			"capture$id" =~ /(capture\d)/;
			$! = 10 + $id;
			$started[$id] = 1;
			my $sum = 0;
			$sum++ until scalar(grep { $_ } @started) == 8;
			die "lost task state\n" unless $value eq "act$id"
				&& $1 eq "capture$id" && 0 + $! == 10 + $id;
			done $wg;
		};
	}
	await $wg;
	die "lost root state\n" unless $value eq 'root';
	print "eight acts retained their state\n";
}, 0, qr/\Aeight acts retained their state\n\z/,
	'automatic switches retain locals, captures, errno, and Perl frames');

WumpTest::check_program(q{
	use Wump;
	use Time::HiRes ();
	alarm 3;
	my ($inside, $overlap) = (0, 0);
	my $wg = waitgroup;
	add $wg;
	act { $overlap = $inside; done $wg };
	package SlowDestructor {
		sub DESTROY {
			$inside = 1;
			my $end = Time::HiRes::time() + 0.03;
			1 while Time::HiRes::time() < $end;
			$inside = 0;
		}
	}
	{ my $object = bless {}, 'SlowDestructor' }
	await $wg;
	die "preempted a destructor\n" if $overlap;
	print "destructor completed before switching\n";
}, 0, qr/\Adestructor completed before switching\n\z/,
	'automatic preemption defers through destructor callbacks');

WumpTest::check_program(q{
	use Wump;
	use Time::HiRes ();
	alarm 3;
	our ($inside, $overlap) = (0, 0);
	sub compiling {
		$inside = 1;
		my $end = Time::HiRes::time() + 0.03;
		1 while Time::HiRes::time() < $end;
		$inside = 0;
	}
	my $wg = waitgroup;
	add $wg;
	act { $overlap = $inside; done $wg };
	eval 'BEGIN { main::compiling() } 1' or die $@;
	await $wg;
	die "preempted the compiler\n" if $overlap;
	print "compilation completed before switching\n";
}, 0, qr/\Acompilation completed before switching\n\z/,
	'compiler callbacks defer automatic preemption');

done_testing;
