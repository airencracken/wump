use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use Wump;

our $package_value = {visits => 0};
my $shared = {visits => 0};
my ($message, $captured);
run {
	my $out = chan;
	act {
		lock $shared;
		$shared->{visits}++;
		$package_value->{visits}++;
		$captured = refaddr($shared);
		$out->send($shared);
	};
	$message = $out->recv;
};
is_deeply($message, {visits => 1}, 'channel receivers observe mutations made by a sender');
is(refaddr($message), refaddr($shared), 'channel transfer preserves the shared referent');
is($captured, refaddr($shared), 'captured lexicals use the same referent as the parent');
is($package_value->{visits}, 1, 'package reference mutations remain shared');

my $destroyed = 0;
{
	package SharedOwned;
	sub DESTROY { $destroyed++ }
}
my $weak;
run {
	my $out = chan(4);
	act {
		for (1..400) {
			my $item = bless {number => $_}, 'SharedOwned';
			$weak = $item;
			weaken($weak);
			$out->send($item);
		}
		$out->close;
	};
	while (my $item = $out->recv) {
		lock $item;
		yield;
		$item->{number}++;
	}
};
is($destroyed, 400, 'buffered shared messages and scoped locks release each object exactly once');
is($weak, undef, 'shared message cleanup invalidates weak references');

run {
	my $out = chan(1);
	act {
		$out->send(bless {}, 'SharedOwned');
		$out->send(bless {}, 'SharedOwned');
	};
	yield;
};
is($destroyed, 402, 'shutdown releases buffered and blocked-send message references');

my $cycle = {};
$cycle->{self} = $cycle;
run {
	my $out = chan;
	act { $out->send($cycle) };
	my $received = $out->recv;
	lock $received;
	$received->{value} = 42;
};
is(refaddr($cycle->{self}), refaddr($cycle), 'channel publication preserves cyclic graph identity');
is($cycle->{value}, 42, 'mutations through a received cyclic reference reach the original');
delete $cycle->{self};

done_testing;
