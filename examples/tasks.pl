use v5.42;
use Wump;

my $results = chan(2);
for my $number (1..4) {
	act {
		sleep 0.001;
		$results->send($number * $number);
	};
}
my @squares;
push @squares, scalar $results->recv for 1..4;
say 'Perl tasks returned: ', join ', ', sort { $a <=> $b } @squares;
