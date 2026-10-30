#!/usr/bin/env perl
use v5.42;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../perl/lib";
BEGIN {
	if (($ENV{WUMP_BASELINE_MODE} // '') eq 'wump') {
		require Wump;
		Wump->import;
	}
}
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
BEGIN { CLOCK_MONOTONIC() }

my ($mode, $iterations, $jobs) = @ARGV;
die "Invalid baseline configuration\n" unless @ARGV == 3
	&& $mode =~ /\A(?:plain|wump)\z/ && $mode eq ($ENV{WUMP_BASELINE_MODE} // '')
	&& $iterations =~ /\A[1-9][0-9]*\z/ && $iterations <= 50_000_000
	&& $jobs =~ /\A[1-9][0-9]*\z/ && $jobs <= 256;

sub compute ($iterations, $id) {
	my $sum = $id;
	$sum += $_ % 97 for 1..$iterations;
	return [$id, $sum];
}

my @cpu_start = times;
my $started = clock_gettime(CLOCK_MONOTONIC);
my @results;
if ($mode eq 'wump') {
	my $out = Wump::chan(4);
	for my $id (1..$jobs) {
		Wump::act(sub { $out->send(compute($iterations, $id)) });
	}
	push @results, scalar $out->recv for 1..$jobs;
} else {
	push @results, compute($iterations, $_) for 1..$jobs;
}
my $wall = clock_gettime(CLOCK_MONOTONIC) - $started;
my @cpu_end = times;
my $cpu = $cpu_end[0] - $cpu_start[0] + $cpu_end[1] - $cpu_start[1];

# An independent closed-form reference catches missing/duplicated jobs and
# wrong arithmetic without timing another copy of the compute loop.
my $remainder = $iterations % 97;
my $expected = int($iterations / 97) * (96 * 97 / 2) + $remainder * ($remainder + 1) / 2;
my %seen;
for my $result (@results) {
	my ($id, $sum) = @$result;
	die "Baseline verification failed\n" unless $id >= 1 && $id <= $jobs
		&& !$seen{$id}++ && $sum == $expected + $id;
}
die "Invalid baseline interval\n" unless $wall > 0;
my $slots = $mode eq 'wump' ? Wump::execution_slots() : 0;
printf "{\"execution_slots\":%d,\"iterations\":%d,\"jobs\":%d,\"verified_jobs\":%d,\"wall_seconds\":%.9f,\"cpu_seconds\":%.6f}\n",
	$slots, $iterations, $jobs, scalar(@results), $wall, $cpu;
