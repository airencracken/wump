use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1,2,4) {
	local $ENV{WUMPPROCS}=$slots;
	WumpTest::check_program(q{
		use Wump;
		use JSON::PP ();
		use RootFixture;
		{ package JsonObject;
			sub TO_JSON {
				my ($self)=@_;
				Wump::yield();
				my $inner=JSON::PP->new->canonical->ascii->encode({nested=>17});
				die "nested encoder changed" unless $inner eq '{"nested":17}';
				return {id=>$self->{id}};
			}
		}
		sub codec ($id) {JSON::PP->new->canonical->utf8($id%2)->ascii(!($id%2))->indent($id%2)->convert_blessed}
		our (@values,@expected,@canonical);
		BEGIN {
			for my $id (1..8) {
				my $value={id=>$id,name=>"Caf\x{e9}\0\x{10000}",list=>[1,{word=>'nested'}],object=>{id=>$id}};
				push @values,$value;
				push @expected,codec($id)->encode($value);
				push @canonical,JSON::PP->new->canonical->ascii->encode($value);
			}
		}
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				my $encoder=codec($id)->sort_by(sub {Wump::yield(); $JSON::PP::a cmp $JSON::PP::b});
				my $decoder=codec($id)->filter_json_object(sub {
					my $value=$_[0];
					Wump::yield();
					my $nested=JSON::PP->new->decode('{"inner":[99]}');
					die "nested parser changed" unless $nested->{inner}[0]==99;
					return $value;
				});
				my $value={%{$values[$id-1]},object=>bless({id=>$id},'JsonObject')};
				for (1..16) {
					my $json=$encoder->encode($value);
					die "encoder options mixed for $id" unless $json eq $expected[$id-1];
					my $decoded=$decoder->decode($json);
					die "parser cursor mixed for $id" unless JSON::PP->new->canonical->ascii->encode($decoded) eq $canonical[$id-1];
					yield;
				}
				$out->send($id);
			};
		}
		my @ids=sort {$a<=>$b} map {scalar $out->recv} 1..8;
		die "missing codec workers" unless join(',',@ids) eq join(',',1..8);
		print "independent and nested codecs verified\n";
	},0,qr/\Aindependent and nested codecs verified\n\z/,
		"codec options and cursors survive yielding/reentrant callbacks on $slots slots");

	WumpTest::check_program(q{
		use Wump; use JSON::PP (); use RootFixture;
		# No functional JSON call before actors rendezvous: exercise cold API use.
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for my $round (1..32) {
					my $value={id=>$id,round=>$round,text=>"\x{100}\0\x{10000}",yes=>JSON::PP::true,no=>JSON::PP::false};
					my $json=JSON::PP::encode_json($value);
					my $copy=JSON::PP::decode_json($json);
					die "functional JSON changed" unless $copy->{id}==$id && $copy->{round}==$round && $copy->{text} eq $value->{text} && $copy->{yes} && !$copy->{no};
					yield;
				}
				$out->send(1);
			};
		}
		die "missing default codec results" if grep {$out->recv!=1} 1..8;
		print "default UTF-8 JSON round trips verified\n";
	},0,qr/\Adefault UTF-8 JSON round trips verified\n\z/,
		"cold functional JSON API handles Unicode, NULs and booleans on $slots slots");

	WumpTest::check_program(q{
		use Wump; use JSON::PP (); use RootFixture;
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				my $codec=JSON::PP->new->utf8->filter_json_object(sub {Wump::yield(); return $_[0]});
				for (1..16) {
					eval {$codec->decode(chr(123).'"broken":')};
					die "invalid JSON did not throw" unless $@;
					die "decoder did not recover" unless $codec->decode('{"ok":42}')->{ok}==42;
					$codec->filter_json_object(sub {Wump::yield(); die "filter failed\n"});
					eval {$codec->decode('{"x":1}')};
					die "callback exception lost" unless $@ =~ /filter failed/;
					$codec->filter_json_object(sub {Wump::yield(); return $_[0]});
					my $incremental=JSON::PP->new->utf8;
					my $json='{"id":'.$id.',"s":"'."\xc4\x80".'"}';
					my $first=$incremental->incr_parse(substr($json,0,length($json)-3));
					die "incremental parser returned early" if defined $first;
					yield;
					my $last=$incremental->incr_parse(substr($json,-3));
					die "incremental parser changed" unless $last->{id}==$id && $last->{s} eq "\x{100}";
				}
				$out->send(1);
			};
		}
		die "missing recovery workers" if grep {$out->recv!=1} 1..8;
		print "JSON unwind and incremental parsing verified\n";
	},0,qr/\AJSON unwind and incremental parsing verified\n\z/,
		"parser errors, yielding exceptions and split UTF-8 recover on $slots slots");
}
done_testing;
