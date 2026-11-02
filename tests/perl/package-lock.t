use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1,4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump;
		use RootFixture;
		our $counter = 0;
		our $alias;
		BEGIN { *alias = \$counter }
		my $reference = \$counter;
		my ($held, $attempted, $release, $finished) = (chan, chan, chan, chan(2));
		act {
			RootFixture::memory_guard($reference, sub {
				$held->send(1);
				$release->recv;
			});
			$finished->send(1);
		};
		$held->recv;
		eval { RootFixture::scalar_publish($reference) };
		die "explicit publication admitted a foreign writer" unless $@ =~ /publication overlaps mutation/;
		eval { my $read = $counter };
		die "ordinary package read admitted a foreign writer" unless $@ =~ /publication overlaps mutation/;
		act {
			$attempted->send(1);
			lock $counter;
			$counter++;
			$finished->send(1);
		};
		$attempted->recv;
		# Let the waiter execute GV lookup while the writer is still parked.
		yield for 1..16;
		$release->send(1);
		die "missing writer or waiter" if grep {$finished->recv != 1} 1..2;
		die "package lock update lost" unless $counter == 1;
		my $group = waitgroup;
		for (1..8) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				for (1..128) {
					if ($_ % 2) { lock $counter; $counter++; yield }
					else { lock $alias; $alias++; yield }
				}
				done $group;
			};
		}
		await $group;
		die "contended package updates lost" unless $counter == 1025;
		print "package lock identities wait for writers and preserve every update\n";
	}, 0, qr/\Apackage lock identities wait for writers and preserve every update\n\z/,
		"package scalar lock operands survive a parked writer and contention on $slots slots");
}
done_testing;
