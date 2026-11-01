use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1,4) {
	local $ENV{WUMPPROCS}=$slots;
	WumpTest::check_program(q{
		use Wump; use Carp (); use RootFixture;
		our $scope='root';
		{ package DB;
			sub snapshot {
				local @DB::args;
				my @frame=caller(1);
				Wump::yield();
				return [@DB::args];
			}
		}
		sub frame {DB::snapshot()}
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				local $scope=$id;
				for my $round (1..16) {
					my $copy=frame($id,$round);
					die "caller arguments crossed acts" unless join(',',@$copy) eq "$id,$round";
					{
						local @DB::args=('outer',$id);
						my $nested=frame($id,$round);
						die "nested caller arguments changed" unless join(',',@$nested) eq "$id,$round";
						die "outer debugger binding lost" unless join(',',@DB::args) eq "outer,$id";
					}
					eval {Carp::croak("diagnostic-$id-$round")};
					die "Carp exception lost" unless index($@,"diagnostic-$id-$round")>=0;
					die "unrelated local binding lost" unless $scope==$id;
				}
				$out->send($id);
			};
		}
		my @ids=sort {$a<=>$b} map {scalar $out->recv} 1..8;
		die "missing caller workers" unless join(',',@ids) eq join(',',1..8);
		die "root localization changed" unless $scope eq 'root';
		print "caller and Carp scratch isolation verified\n";
	},0,qr/\Acaller and Carp scratch isolation verified\n\z/,
		"caller arguments, nested scratch and exception recovery on $slots slots");

	WumpTest::check_program(q{
		use Wump; use RootFixture;
		BEGIN {@DB::args=('root debugger scratch')}
		{ package DB;
			sub export_args {
				my ($out)=@_;
				local @DB::args;
				my @frame=caller(1);
				Wump::yield();
				die "shifted argument prefix inspected" if defined $DB::args[0];
				eval {RootFixture::publish_debug_args()};
				die "borrowed debugger storage escaped" unless $@ =~ /cannot publish borrowed debugger arguments/;
				$out->send([@DB::args]);
			}
		}
		sub shifted {
			my $out=shift;
			DB::export_args($out);
		}
		my $out=chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				$!=$id;
				$?=$id<<8;
				$^F=$id+100;
				for (1..16) {
					yield;
					die "native builtin cache mixed" unless 0+$! == $id && $? == $id<<8 && $^F == $id+100;
					my $line=$.;
					die "unexpected line count" if defined($line) && $line!=0;
				}
				shifted($out,$id);
			};
		}
		my @ids;
		for (1..8) {
			my $copy=$out->recv;
			die "owned argument copy changed" unless @$copy==2 && !defined $copy->[0];
			push @ids,$copy->[1];
		}
		die "missing argument copies" unless join(',',sort {$a<=>$b} @ids) eq join(',',1..8);
		my $root=RootFixture::root_debug_args();
		die "root debugger scratch changed" unless @$root==1 && $root->[0] eq 'root debugger scratch';
		print "borrow boundaries and builtin caches verified\n";
	},0,qr/\Aborrow boundaries and builtin caches verified\n\z/,
		"borrowed argument lifetime, copies and native builtin caches on $slots slots");
}
done_testing;
