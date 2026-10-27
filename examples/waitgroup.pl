use v5.42;
use strict;
use warnings;
use Wump;

my $wg = waitgroup;
my @squares;
for my $number (1..4) {
	add $wg;
	act {
		yield;
		push @squares, $number * $number;
		done $wg;
	};
}
await $wg;
say 'Function form: ', join ', ', sort {$a <=> $b} @squares;

my $workers = Wump::WaitGroup->new;
$workers->add(2);
for my $name ('alpha', 'bravo') {
	act { say "Object form: $name"; $workers->done };
}
$workers->wait;
