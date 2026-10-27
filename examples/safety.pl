use v5.42;
use strict;
use warnings;
use Wump;

my $totals = {visits => 0};
my @reports;
scope {
	my $done = chan;
	local $SIG{__WARN__} = sub { push @reports, "inherited: $_[0]" };
	pocket $SIG{__WARN__} = sub { push @reports, "parent only: $_[0]" };
	for my $name ('alpha', 'bravo') {
		act {
			local $^W = 1;
			for (1..10) {
				lock $totals;
				my $old = $totals->{visits};
				yield;
				$totals->{visits} = $old + 1;
			}
			warn "$name finished\n";
			$done->send($totals);
		};
	}
	warn "waiting for workers\n";
	$done->recv for 1..2;
};
print @reports;
say "shared visits: $totals->{visits}";
