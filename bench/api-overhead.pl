use v5.42;
use strict;
use warnings;
use Wump;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP ();
use B ();
BEGIN {
	CLOCK_MONOTONIC();
	die "native yield opcode is unavailable\n"
		if ($ARGV[1] // '') eq 'native' && B::opnumber('wumpyield') < 0;
}

# Diagnostic ablation: internal XS calls are not a supported public API.
# Each pair performs the same work, removing only the Perl API wrapper.
@ARGV == 3 or die "usage: api-overhead.pl yield|spawn public|xs|native ITERATIONS\n";
my ($op, $mode, $n) = @ARGV;
$op =~ /\A(?:yield|spawn)\z/ && $mode =~ /\A(?:public|xs|native)\z/
	&& !($op eq 'spawn' && $mode eq 'native')
	&& $n =~ /\A[1-9][0-9]*\z/ && $n <= 2000000 or die "invalid probe workload\n";
my $count = 0;
my $start = clock_gettime(CLOCK_MONOTONIC);
if ($op eq 'yield') {
	if ($mode eq 'public') { for (1..$n) { Wump::yield(); $count++ } }
	elsif ($mode eq 'native') { for (1..$n) { yield; $count++ } }
	else { for (1..$n) { Wump::_yield(); $count++ } }
} else {
	my $out = Wump::chan();
	for (my $base = 0; $base < $n; $base += 1024) {
		my $batch = $n - $base < 1024 ? $n - $base : 1024;
		if ($mode eq 'public') {
			for (1..$batch) { Wump::act(sub { $out->send(1) }) }
		} else {
			# Leave channel methods intact to isolate act's wrapper alone.
			for (1..$batch) { Wump::_act(sub { $out->send(1) }) }
		}
		for (1..$batch) {
			my $reply = $out->recv;
			die "bad completion\n" unless $reply == 1;
			$count++;
		}
	}
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
die "incomplete probe\n" unless $count == $n;
print JSON::PP->new->ascii->canonical->encode({operation => $op, mode => $mode, iterations => 0 + $n,
	slots => Wump::execution_slots(), completed => $count, wall_seconds => $elapsed}), "\n";
