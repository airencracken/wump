use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

# Keep the harness outside the scheduler. Every child runs ordinary Perl
# closures on one shared interpreter; the fixture reports its actual address.
my $pool = q{
	use Wump;
	use RootFixture;
	my $parent = RootFixture::execution_context();
	die "wrong slot count\n" unless $parent->[3] == $ENV{WUMPPROCS};
	sub compute ($n) {
		eval { die "caught-$n\n" };
		my $caught = $@;
		yield;
		die "exception state changed\n" unless $caught eq "caught-$n\n" && $@ eq $caught;
		my $sum = 0;
		$sum += $_ % 17 for 1..$n;
		return $sum;
	}
	my $jobs = chan(4);
	my $results = chan(4);
	my $group = waitgroup;
	my $total = 0;
	for (1..16) {
		add $group;
		act {
			while (my ($job, $ok) = $jobs->recv) {
				last unless $ok;
				my $context = RootFixture::executor_rendezvous();
				my $sum = compute($job);
				{
					lock $total;
					$total += $sum;
					yield;
				}
				my $local = waitgroup;
				add $local;
				act { done $local };
				await $local;
				my $local_channel = chan(1);
				$local_channel->send([$job, $sum, $context]);
				$results->send(scalar $local_channel->recv);
			}
			done $group;
		};
	}
	add $group;
	act { $jobs->send($_) for 1001..1048; $jobs->close; done $group };
	my (%seen, %workers, %acts);
	my $expected_total = 0;
	for (1..48) {
		my ($job, $sum, $context) = @{$results->recv};
		die "wrong result\n" unless $sum == compute($job);
		die "interpreter was cloned\n" unless $context->[0] == $parent->[0];
		die "act state was shared\n" if $context->[1] == $parent->[1];
		$expected_total += $sum;
		$workers{$context->[2]}++;
		$acts{$context->[1]}++;
		$seen{$job}++;
	}
	await $group;
	die "missing jobs\n" unless keys(%seen) == 48;
	die "duplicate job\n" if grep { $_ != 1 } values %seen;
	die "lock lost an update\n" unless $total == $expected_total;
	die "one act consumed every job\n" unless keys(%acts) > 1;
	die "one slot executed every job\n" if $parent->[3] > 1 && keys(%workers) < 2;
	print "one interpreter, private act state, correct jobs, locks and nested waits\n";
};
for my $procs (1, 2, 4) {
	local $ENV{WUMPPROCS} = $procs;
	WumpTest::check_program($pool, 0,
		qr/\Aone interpreter, private act state, correct jobs, locks and nested waits\n\z/,
		"worker pool runs with $procs execution slots");
}

{
	local $ENV{WUMPPROCS} = 1;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		eval { RootFixture::metadata_guard(sub { yield }) };
		die "native guard scheduled: $@" unless $@ =~ /scheduling inside a native metadata operation/;
		eval { RootFixture::metadata_guard(sub { die "callback failed\n" }) };
		die "metadata exception changed: $@" unless $@ eq "callback failed\n";
		my $out = chan; act { $out->send(42) };
		die "metadata lock leaked\n" unless $out->recv == 42;
		print "metadata guard unwound before scheduling resumed\n";
	}, 0, qr/\Ametadata guard unwound before scheduling resumed\n\z/,
		'metadata guards reject scheduling and release their locks on exceptions');
}

{
	open my $input, '<', 'bench/perl-parallel.pl' or die "parallel benchmark: $!";
	my $strings = do { local $/; <$input> };
	close $input or die "parallel benchmark: $!";
	local $ENV{WUMPPROCS} = 4;
	WumpTest::check_program($strings, 0, qr/\Afour string workers verified\n\z/,
		'parallel string workers preserve their private buffers');
}

for my $invalid ('', '0', '-1', '257', '4x', '999999999999999999999') {
	local $ENV{WUMPPROCS} = $invalid;
	WumpTest::check_program('use Wump; print "invalid setting ran\n";', 255,
		qr/\AWump: WUMPPROCS must be an integer from 1 to 256/,
		'invalid slot count is rejected before scheduling');
}

{
	local $ENV{WUMPPROCS} = 4;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		BEGIN { RootFixture::debug_runops() }
		print "custom runloop ran\n";
	}, 255, qr/\AWump: custom runloops are not supported during parallel execution/,
		'parallel startup rejects runloops that bypass its compiler gate');
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		my $value = 40;
		eval { RootFixture::unguarded_increment(\$value) };
		die "unsafe XS ran: $@" unless $@ =~ /XS function has not declared parallel safety/;
		die "unsafe XS changed its target\n" unless $value == 40;
		print "unsafe XS rejected before invocation\n";
	}, 0, qr/\Aunsafe XS rejected before invocation\n\z/,
		'parallel execution rejects unaudited XS before it accesses values');
	WumpTest::check_program(q{
		use Wump;
		my $value = 40;
		eval { eval '$value = 99' };
		die "runtime compiler ran: $@" unless $@ =~ /runtime compilation is not supported/;
		die "runtime compiler changed its target\n" unless $value == 40;
		print "runtime compiler rejected before entry\n";
	}, 0, qr/\Aruntime compiler rejected before entry\n\z/,
		'parallel execution rejects runtime compilation before compiler state changes');
	for my $operation (
		q{require No::Such::WumpModule},
		q{do './no-such-wump-file.pl'},
		q{my $pattern = 'dynamic'; 'dynamic' =~ /$pattern/},
	) {
		WumpTest::check_program('use Wump; eval { ' . $operation . q! };
			die "compiler gate bypassed: $@" unless $@ =~ /runtime compilation is not supported/;
			print "compiler entry rejected\n";
		!, 0, qr/\Acompiler entry rejected\n\z/,
			"parallel compiler gate rejects $operation");
	}
	WumpTest::check_program(q{
		use Wump;
		our $ready = chan(6);
		for (1..6) {
			act { $ready->send(1); my $n = 0; $n++ while 1 };
		}
		$ready->recv for 1..6;
		END { print "main END completed\n" }
	}, 0, qr/\Amain END completed\n\z/,
		'main shutdown stops running compute acts after entering END');
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		my $destroyed = 0;
		package Cleanup {
			use Wump;
			sub DESTROY {
				my $reply = chan;
				act { $reply->send(21) };
				yield;
				die "destructor callback lost its result\n" unless $reply->recv == 21;
				lock $destroyed;
				$destroyed++;
			}
		}
		my $group = waitgroup;
		for (1..16) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				{ my $owned = bless {}, 'Cleanup' }
				done $group;
			};
		}
		await $group;
		die "destructor cleanup failed: $destroyed\n" unless $destroyed == 16;
		print "parallel destructors completed their yielding callbacks\n";
	}, 0, qr/\Aparallel destructors completed their yielding callbacks\n\z/,
		'concurrent DESTROY lookups release metadata guards before callbacks');
	WumpTest::check_program(q{
		use Wump;
		my $start = chan;
		act { $start->recv; die "parallel panic\n" };
		act { $start->recv; die "parallel panic\n" };
		$start->close;
		my $park = chan; $park->recv;
	}, 2, qr/\Atask [23] \[panic\]: parallel panic\n\z/,
		'competing child panics report one error and stop all executors');
}

done_testing;
