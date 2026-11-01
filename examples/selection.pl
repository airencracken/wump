use v5.42;
use strict;
use warnings;
use Wump;

my ($work, $results, $done, $exited) = (chan(), chan(8), chan(), chan());
for (1..4) {
	act {
		while (1) {
			my ($index, $value, $ok) = sel([
				['recv', $work],
				['recv', $done],
			]);
			last if $index == 1 || !$ok;
			$results->send($value * $value);
		}
		$exited->send(1);
	};
}
$work->send($_) for 1..8;
my @squares;
for (1..8) {
	my ($index, $value, $ok) = sel([['recv', $results]], 1);
	die "result deadline expired\n" unless defined($index) && $ok;
	push @squares, $value;
}
# Close broadcasts cancellation to every worker's pending selection. Wait for
# explicit acknowledgments before main return stops the runtime.
$done->close;
$exited->recv for 1..4;
say join ' ', sort {$a <=> $b} @squares;
