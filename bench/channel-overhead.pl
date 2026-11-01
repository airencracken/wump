use v5.42;
use strict;
use warnings;
use Wump;
use B ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP ();
BEGIN { CLOCK_MONOTONIC() }

{
	package Wump::Bench::WrapperChannel;
	our @ISA = ('Wump::Channel');
	sub send { Wump::_send(@_); return }
	sub recv { Wump::_recv(@_) }
	sub close { Wump::_close(@_); return }
	package Wump::Bench::XSChannel;
	our @ISA = ('Wump::Channel');
	BEGIN { *send=\&Wump::_send; *recv=\&Wump::_recv; *close=\&Wump::_close }
}

@ARGV == 3 or die "usage: channel-overhead.pl buffered|rendezvous wrapper|xs|native ITERATIONS\n";
my ($operation,$mode,$n) = @ARGV;
$operation =~ /\A(?:buffered|rendezvous)\z/ && $mode =~ /\A(?:wrapper|xs|native)\z/
	&& $n =~ /\A[1-9][0-9]*\z/ && $n <= 2000000 or die "invalid channel probe\n";
CHECK {
	if (($ARGV[1] // '') eq 'native') {
		no strict 'refs';
		for my $name (qw(send recv close)) {
			my $method = Wump::Channel->can($name);
			die "native channel $name entry is unavailable\n"
				unless defined &{"Wump::_channel_$name"} && B::svref_2object($method)->XSUB
				&& $method == \&{"Wump::_channel_$name"};
		}
	}
}
my $class = $mode eq 'wrapper' ? 'Wump::Bench::WrapperChannel'
	: $mode eq 'xs' ? 'Wump::Bench::XSChannel' : 'Wump::Channel';
sub channel ($capacity,$class) {
	my $owner = Wump::chan($capacity);
	my $id = $$owner;
	return bless \$id,$class;
}
my $request = channel($operation eq 'buffered' ? 1 : 0,$class);
my $response = channel(0,$class);
my $done = channel(0,$class);
if ($operation eq 'rendezvous') {
	act {
		for (1..$n) {
			my $value = $request->recv;
			$response->send($value+1);
		}
		$done->send(1);
	}
}
my ($count,$sum) = (0,0);
my $start = clock_gettime(CLOCK_MONOTONIC);
for my $id (1..$n) {
	$request->send($id);
	my $reply = $operation eq 'buffered' ? scalar $request->recv : scalar $response->recv;
	die "bad channel reply\n" unless $reply == $id + ($operation eq 'rendezvous' ? 1 : 0);
	$sum += $reply;
	$count++;
}
if ($operation eq 'rendezvous') { die "missing worker completion\n" unless $done->recv == 1 }
my $elapsed = clock_gettime(CLOCK_MONOTONIC)-$start;
$_->close for ($request,$response,$done);
my $expected = $n*($n+1)/2 + ($operation eq 'rendezvous' ? $n : 0);
die "incomplete channel probe\n" unless $count == $n && $sum == $expected;
print JSON::PP->new->ascii->canonical->encode({operation=>$operation,mode=>$mode,
	iterations=>0+$n,slots=>Wump::execution_slots(),completed=>$count,checksum=>$sum,wall_seconds=>$elapsed}),"\n";
