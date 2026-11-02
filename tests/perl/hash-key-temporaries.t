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
		our %hash;
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..64) {
					local %hash=(id=>$id);
					yield;
					die "literal-key assignment changed" unless $hash{id}==$id && keys(%hash)==1;
					%hash=(id=>$hash{id}+100);
					yield;
					die "common hash assignment changed" unless $hash{id}==$id+100 && keys(%hash)==1;
				}
				$out->send($id);
			};
		}
		my @ids=sort {$a<=>$b} map {scalar $out->recv} 1..8;
		die "missing hash workers" unless join(',',@ids) eq join(',',1..8) && !%hash;
		print "shared literal keys survive temporary cleanup\n";
	},0,qr/\Ashared literal keys survive temporary cleanup\n\z/,
		"shared hash keys keep private temporary ownership on $slots slots");

	WumpTest::check_program(q{
		use Wump; use RootFixture;
		{ package RetainedKey;
			use overload '""'=>sub {
				my ($self)=@_;
				Wump::yield();
				die "key conversion failed\n" if $self->{throw};
				return $self->{name};
			}, fallback=>1;
			sub DESTROY {${$_[0]->{count}}++}
		}
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				my $destroyed=0;
				my %hash=(source=>bless({name=>"key-$id",count=>\$destroyed},'RetainedKey'));
				%hash=($hash{source}=>17);
				die "retained key lost through conversion" unless $hash{"key-$id"}==17 && keys(%hash)==1;
				die "successful key lifetime leaked" unless $destroyed==1;
				%hash=(source=>bless({throw=>1,count=>\$destroyed},'RetainedKey'));
				eval {%hash=($hash{source}=>18)};
				die "key conversion exception lost" unless $@ =~ /key conversion failed/;
				die "throwing key lifetime leaked" unless $destroyed==2;
				%hash=(recovered=>$id);
				die "hash assignment did not recover" unless $hash{recovered}==$id;
				$out->send(1);
			};
		}
		die "missing retained-key workers" if grep {$out->recv!=1} 1..8;
		print "aliased keys survive yielding conversion and unwind\n";
	},0,qr/\Aaliased keys survive yielding conversion and unwind\n\z/,
		"aliased key identity, destruction and throwing conversion on $slots slots");
}
done_testing;
