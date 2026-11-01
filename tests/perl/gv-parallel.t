use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1,4) {
	local $ENV{WUMPPROCS}=$slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		use JSON::PP ();
		our ($a,$b);
		sub compare {Wump::yield(); $a <=> $b}
		my ($ready,$out)=(chan(),chan(4));
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..64) {
					my @values=sort compare (8,1,7,2,6,3,5,4);
					die "sort globals mixed" unless join(',',@values) eq '1,2,3,4,5,6,7,8';
					my $true=JSON::PP::true;
					my $false=JSON::PP::false;
					die "boolean class lost" unless blessed($true) eq 'JSON::PP::Boolean' && blessed($false);
					die "boolean value lost" unless $true && !$false;
					yield;
				}
				$out->send($id);
			};
		}
		my @ids=sort {$a<=>$b} map {scalar $out->recv} 1..8;
		die "missing namespace workers" unless join(',',@ids) eq join(',',1..8);
		print "glob metadata and class queries verified\n";
	},0,qr/\Aglob metadata and class queries verified\n\z/,
		"sort lookup, builtin class queries and cold overload caches on $slots slots");
}
done_testing;
