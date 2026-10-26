use v5.42;
use Wump;

sub parse ($text, $results) {
	$text =~ /(?<name>[a-z]+)-(?<number>\d+)/ or die 'invalid input';
	yield;
	$results->send("$text retained $+{name} and $+{number}");
}

run {
	my $results = chan;
	act { parse('alpha-11', $results) };
	act { parse('bravo-22', $results) };
	say scalar $results->recv for 1..2;
};
