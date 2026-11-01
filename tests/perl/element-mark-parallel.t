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
		my @origins=map {{id=>$_,value=>'root',array=>['base']}} 1..256;
		my ($messages,$finished)=(chan(8),chan());
		for my $id (1..4) {
			act {
				RootFixture::executor_rendezvous();
				for my $origin (@origins) {
					local $origin->{value}=$id;
					local $origin->{array}[0]=$id;
					local $SIG{__WARN__}=sub {};
					yield;
					die "local view mixed" unless $origin->{value}==$id;
					die "local array view mixed" unless $origin->{array}[0]==$id;
					$messages->send($origin);
				}
				$finished->send(1);
			};
		}
		for (1..4) {
			act {
				RootFixture::executor_rendezvous();
				for my $origin (@origins) {
					# Send republishes a new RV head and visits the shared origin.
					$messages->send($origin);
					yield;
				}
				$finished->send(1);
			};
		}
		my $sum=0;
		for (1..8*256) {
			my $origin=$messages->recv;
			die "localized value escaped" unless $origin->{value} eq 'root';
			die "localized array escaped" unless $origin->{array}[0] eq 'base';
			$sum+=$origin->{id};
		}
		$finished->recv for 1..8;
		die "publication lost messages" unless $sum==8*256*257/2;
		die "base value changed" if grep {$_->{value} ne 'root'} @origins;
		print "element markers and publication verified\n";
	},0,qr/\Aelement markers and publication verified\n\z/,
		"first localization and publication preserve every task view on $slots slots");
}
done_testing;
