use v5.42;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../perl/lib";
BEGIN {
	if (($ENV{WUMP_MATRIX_MODE} // '') eq 'wump') {
		require Wump;
		Wump->import;
	}
}
use JSON::PP ();
use Encode ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
our $encoder;
BEGIN { CLOCK_MONOTONIC(); $encoder = Encode::find_encoding('UTF-8') }

@ARGV == 3 or die "usage: matrix-worker.pl OPERATION ITERATIONS JOBS\n";
my ($op, $n, $jobs) = @ARGV;
$op =~ /\A(?:arithmetic|calls|arrays|hashes|strings|regex|utf8|json|yield|spawn|channel)\z/
	&& $n =~ /\A[1-9][0-9]*\z/ && $n <= 2000000
	&& $jobs =~ /\A[1-9][0-9]*\z/ && $jobs <= 64 or die "invalid matrix workload\n";
my $active = ($ENV{WUMP_MATRIX_MODE} // '') eq 'wump';
my $slots = $active ? Wump::execution_slots() : 0;
my $primitive = $op =~ /\A(?:yield|spawn|channel)\z/;
die "coroutines require an active runtime\n" if $primitive && !$active;

sub emit ($value) { print JSON::PP->new->ascii->canonical->encode($value), "\n" }
my %identity = (operation => $op, iterations => 0 + $n, jobs => 0 + $jobs, slots => $slots);
if ($op eq 'json') {
	my $ok = eval { JSON::PP::encode_json({n => 1, s => 'word'}); 1 };
	if (!$ok) {
		my $error = $@;
		die $error unless $active && $slots > 1
			&& $error =~ /XS function has not declared parallel safety: utf8::encode\b/;
		emit({%identity, status => 'unsupported', reason => 'parallel XS admission: utf8::encode', detail => $error});
		exit;
	}
}

sub increment ($value) { return $value + 1 }
sub compute ($id) {
	my ($sum, $last) = (0, '');
	if ($op eq 'arithmetic') {
		$sum += ($_ + $id) % 97 for 0..$n - 1;
	} elsif ($op eq 'calls') {
		$sum += increment(($_ + $id) % 97) for 0..$n - 1;
	} elsif ($op eq 'arrays') {
		my @retained;
		for my $i (0..$n - 1) {
			my $x = ($i + $id) % 97;
			my $value = [$x, $x + 1, $x + 2, $x + 3];
			$retained[$i % 32] = $value;
			$sum += $value->[0] + $value->[1] + $value->[2] + $value->[3];
		}
	} elsif ($op eq 'hashes') {
		my %value = (a => 0, b => 0, c => 0);
		for my $i (0..$n - 1) {
			$value{a} = ($i + $id) % 97;
			$value{b} = $value{a} + 1;
			$value{c} = $value{a} + $value{b};
			$sum += $value{c};
		}
	} elsif ($op eq 'strings') {
		for my $i (0..$n - 1) {
			my $text = 'abc' . (($i + $id) % 97) . ':xyz';
			$sum += length($text) + length(substr($text, 0, 3));
		}
	} elsif ($op eq 'regex') {
		for my $i (0..$n - 1) {
			my $text = 'word:' . (($i + $id) % 97);
			$text =~ /\A([a-z]+):([0-9]+)\z/ or die "regex mismatch\n";
			$sum += length($1) + $2;
		}
	} elsif ($op eq 'utf8') {
		for my $i (0..$n - 1) {
			my $text = chr(0x3bb) . chr(65 + ($i + $id) % 97 % 26);
			my $bytes = $encoder->encode($text, 0);
			$sum += $_ for unpack 'C*', $bytes;
		}
	} elsif ($op eq 'json') {
		for my $i (0..$n - 1) {
			$last = JSON::PP::encode_json({n => ($i + $id) % 97, s => 'word'});
			$sum += length($last);
		}
	}
	return $op eq 'json' ? [$id, $sum, $last] : [$id, $sum];
}

my @results;
my $start = clock_gettime(CLOCK_MONOTONIC);
if (!$primitive) {
	if ($active) {
		my $out = Wump::chan(4);
		for my $id (1..$jobs) { Wump::act(sub { $out->send(compute($id)) }) }
		push @results, scalar $out->recv for 1..$jobs;
	} else { push @results, compute($_) for 1..$jobs }
} elsif ($op eq 'yield') {
	my $count = 0;
	for (1..$n) { Wump::yield(); $count++ }
	push @results, [1, $count];
} elsif ($op eq 'spawn') {
	my $out = Wump::chan();
	my %seen;
	my $sum = 0;
	for (my $base = 0; $base < $n; $base += 1024) {
		my $batch = $n - $base < 1024 ? $n - $base : 1024;
		for my $id ($base + 1..$base + $batch) { Wump::act(sub { $out->send($id) }) }
		for (1..$batch) {
			my $id = $out->recv;
			die "duplicate or invalid spawn result\n" unless $id >= 1 && $id <= $n && !$seen{$id}++;
			$sum += $id;
		}
	}
	push @results, [1, $sum];
} else {
	my ($request, $response, $done) = (Wump::chan(), Wump::chan(), Wump::chan());
	Wump::act(sub {
		for (1..$n) { my $value = $request->recv; $response->send($value + 1) }
		$done->send(1);
	});
	my $sum = 0;
	for my $i (0..$n - 1) {
		$request->send($i);
		my $reply = $response->recv;
		die "channel reply mismatch\n" unless $reply == $i + 1;
		$sum += $reply;
	}
	die "channel worker did not complete\n" unless $done->recv == 1;
	push @results, [1, $sum];
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
emit({%identity, status => 'ok', units => $n * ($primitive ? 1 : $jobs),
	wall_seconds => $elapsed, results => \@results});
