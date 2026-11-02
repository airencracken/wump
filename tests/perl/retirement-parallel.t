use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1,4) {
	local $ENV{WUMPPROCS} = $slots;
	for my $storage (qw(my our)) {
		my $code = q{
			use Wump;
			use RootFixture;
			STORAGE $destroyed = 0;
			{ package RetiredParallel;
				sub DESTROY { lock $destroyed; $destroyed++ }
			}
			my $group = waitgroup;
			for my $id (1..8) {
				add $group;
				act {
					RootFixture::executor_rendezvous();
					for my $round (1..64) {
						my $expected = "borrowed-$id-$round";
						my @values = ($expected, bless({}, 'RetiredParallel'));
						RootFixture::scalar_publish(\@values);
						my $seen = RootFixture::memory_borrow(\@values, 1, sub {
							yield;
							RootFixture::memory_container(\@values, 3);
							yield;
						});
						die "borrowed storage changed" unless $seen eq $expected;
						die "array was not cleared" if @values;
					}
					done $group;
				};
			}
			await $group;
			my $quiet = 0;
			for (1..1024) {
				my ($pins, $pending) = @{RootFixture::memory_stats()};
				if (!$pins && !$pending) { $quiet = 1; last }
				yield;
			}
			die "retirement did not quiesce" unless $quiet;
			{
				lock $destroyed;
				die "retired object lifetime changed: $destroyed" unless $destroyed == 512;
			}
			print "parallel retirement preserves borrowed storage and destroys every object once\n";
		};
		$code =~ s/STORAGE/$storage/;
		WumpTest::check_program($code, 0,
			qr/\Aparallel retirement preserves borrowed storage and destroys every object once\n\z/,
			"retirement and last-pin collection with $storage counter across eight acts on $slots slots");
	}
}
done_testing;
