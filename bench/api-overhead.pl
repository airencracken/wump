use v5.42;
use strict;
use warnings;
use Wump;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP ();
use B ();
BEGIN {
	CLOCK_MONOTONIC();
	my %opcodes = (spawn => 'wumpact', yield => 'wumpyield', chan => 'wumpchan', sleep => 'wumpsleep');
	my $opcode = $opcodes{$ARGV[0] // ''} // 'unknown';
	die "native $opcode opcode is unavailable\n"
		if ($ARGV[1] // '') eq 'native' && B::opnumber($opcode) < 0;
}
CHECK {
	if (($ARGV[1] // '') eq 'native') {
		my %opcodes = (spawn => 'wumpact', yield => 'wumpyield', chan => 'wumpchan', sleep => 'wumpsleep');
		my $expected = $opcodes{$ARGV[0] // ''} // 'unknown';
		my ($found, $walk);
		$walk = sub ($op) {
			while ($$op) {
				$found = 1 if $op->name eq $expected;
				$walk->($op->first) if $op->can('first');
				$op = $op->sibling;
			}
		};
		$walk->(B::main_root());
		die "native $expected was not compiled\n" unless $found;
	}
}

# Diagnostic ablation: internal XS calls are not a supported public API.
# Matching loops compare wrapper, direct XS and native opcode dispatch.
@ARGV == 3 or die "usage: api-overhead.pl yield|spawn|chan|sleep public|xs|native ITERATIONS\n";
my ($op, $mode, $n) = @ARGV;
$op =~ /\A(?:yield|spawn|chan|sleep)\z/ && $mode =~ /\A(?:public|xs|native)\z/
	&& $n =~ /\A[1-9][0-9]*\z/ && $n <= 2000000 or die "invalid probe workload\n";
my $count = 0;
my $start = clock_gettime(CLOCK_MONOTONIC);
if ($op eq 'yield') {
	if ($mode eq 'public') { for (1..$n) { Wump::yield(); $count++ } }
	elsif ($mode eq 'native') { for (1..$n) { yield; $count++ } }
	else { for (1..$n) { Wump::_yield(); $count++ } }
} elsif ($op eq 'sleep') {
	if ($mode eq 'public') { for (1..$n) { Wump::sleep(0); $count++ } }
	elsif ($mode eq 'native') { for (1..$n) { sleep(0); $count++ } }
	else { for (1..$n) { Wump::_sleep(0); $count++ } }
} elsif ($op eq 'chan') {
	if ($mode eq 'public') { for (1..$n) { my $ch = Wump::chan(1); $ch->close; $count++ } }
	elsif ($mode eq 'native') { for (1..$n) { my $ch = chan(1); $ch->close; $count++ } }
	else { for (1..$n) { my $ch = Wump::_chan(1); $ch->close; $count++ } }
} else {
	my $out = Wump::chan();
	for (my $base = 0; $base < $n; $base += 1024) {
		my $batch = $n - $base < 1024 ? $n - $base : 1024;
		if ($mode eq 'public') {
			for (1..$batch) { Wump::act(sub { $out->send(1) }) }
		} elsif ($mode eq 'native') {
			for (1..$batch) { act { $out->send(1) } }
		} else {
			# Leave channel methods intact across all three creation paths.
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
