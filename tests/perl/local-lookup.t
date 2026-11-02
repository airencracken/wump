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
		our ($plain,$separator,@array,%hash);
		BEGIN {*separator=\$/}
		$plain=0;
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				local $/="$id:outer";
				local $plain=$id;
				local $separator="$id:alias";
				local @array=($id);
				local %hash=(id=>$id);
				{
					local $/="$id:inner";
					local $plain=$id+100;
					yield;
					die "newer builtin alias lost" unless $separator eq "$id:inner" && $/ eq $separator;
					die "ordinary binding lost" unless $plain==$id+100 && $array[0]==$id && $hash{id}==$id;
				}
				eval {
					local $separator="$id:throw";
					local $SIG{__WARN__}=sub {Wump::yield()};
					local $plain=$id+200;
					warn "probe warning\n";
					die "lookup unwind\n";
				};
				die "exception lost" unless $@ eq "lookup unwind\n";
				die "scope restoration lost" unless $separator eq "$id:alias" && $/ eq $separator && $plain==$id;
				{
					pocket $separator="$id:private";
					my $child=chan(1);
					act {$child->send([$/,$separator,$plain,$array[0],$hash{id}])};
					my $seen=$child->recv;
					die "inheritance precedence changed" unless $seen->[0] eq "$id:alias" && $seen->[1] eq $seen->[0]
						&& $seen->[2]==$id && $seen->[3]==$id && $seen->[4]==$id;
					die "pocket binding lost" unless $/ eq "$id:private" && $separator eq $/;
				}
				$out->send($id);
			};
		}
		my @ids=sort {$a<=>$b} map {scalar $out->recv} 1..8;
		die "missing lookup workers" unless join(',',@ids) eq join(',',1..8);
		die "root bindings changed" unless $plain==0 && $/ eq "\n" && $separator eq $/ && !@array && !%hash;
		print "binding precedence and restoration verified\n";
	},0,qr/\Abinding precedence and restoration verified\n\z/,
		"ordinary, magical and inherited binding precedence on $slots slots");
}

for my $slots (1,4) {
	local $ENV{WUMPPROCS}=$slots;
	WumpTest::check_program(q{
	use Wump;
	our (@destroyed,$source,$replacement);
	{ package LookupLifetime;
		sub DESTROY {push @main::destroyed,$_[0]->{name}}
	}
	$source=bless({name=>'root'},'LookupLifetime');
	$replacement='replacement';
	my $done=chan;
	act {
		{
			local $source=bless({name=>'local'},'LookupLifetime');
			no warnings 'once';
			*source=*replacement;
			die "glob replacement lost" unless $source eq 'replacement';
			die "old GP freed during replacement" if @destroyed;
			yield;
		}
		die "local or original GP leaked" unless join(',',@destroyed) eq 'local,root';
		$done->send(1);
	};
	$done->recv;
	die "replacement restored over" unless $source eq 'replacement' && $replacement eq 'replacement';
	print "replaced GP lifetime verified\n";
},0,qr/\Areplaced GP lifetime verified\n\z/,
		"private bindings retain a replaced GP and release its values on $slots slots");
}
done_testing;
