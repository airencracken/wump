#!/usr/bin/env perl
use v5.42;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../perl/lib", "$FindBin::Bin/../examples/mojo/lib";
use Wump;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use WumpDemo::Jobs;
use WumpDemo::Analysis qw(reference summary);
BEGIN { CLOCK_MONOTONIC() }

@ARGV <= 3 or die "Usage: $0 [JOBS [PASSES [WORKERS]]]\n";
my ($jobs, $passes, $workers) = ($ARGV[0] // 8, $ARGV[1] // 20, $ARGV[2] // 4);
for my $setting ([$jobs, 256, 'jobs'], [$passes, 100, 'passes'], [$workers, 64, 'workers']) {
	die "Invalid $setting->[2]\n" unless $setting->[0] =~ /\A[1-9][0-9]*\z/ && $setting->[0] <= $setting->[1];
}

sub same_result ($got, $expected) {
	for my $key (qw(lines words unique_words)) {
		return 0 unless defined($got->{$key}) && $got->{$key} == $expected->{$key};
	}
	my @levels = sort keys %{$expected->{levels}};
	return 0 unless join(',', sort keys %{$got->{levels}}) eq join(',', @levels);
	for my $level (@levels) { return 0 unless $got->{levels}{$level} == $expected->{levels}{$level} }
	return 0 unless @{$got->{top_words}} == @{$expected->{top_words}};
	for my $i (0..$#{$expected->{top_words}}) {
		return 0 unless $got->{top_words}[$i]{word} eq $expected->{top_words}[$i]{word}
			&& $got->{top_words}[$i]{count} == $expected->{top_words}[$i]{count};
	}
	return 1;
}

# Identical work for each slot count. The reference counts a whole input once
# and scales; workers repeatedly scan chunks and the collector merges them.
my $text = "INFO Caf\x{e9} cafe\x{301} Stra\x{df}e cache hit\nWARN can't can\x{2019}t cache miss\n" x 64;
my $expected = summary(reference($text, $passes));
my $service = WumpDemo::Jobs->new(workers => $workers, max_active => $jobs,
	max_history => $jobs, chunk_lines => 16);
my @cpu_start = times;
my $start = clock_gettime(CLOCK_MONOTONIC);
$service->start;
my @ids;
for (1..$jobs) {
	my ($id, $status, $error) = $service->submit($text, $passes);
	die "Benchmark admission failed: $status " . ($error // '') . "\n" unless $status == 202;
	push @ids, $id;
}
my @pending = @ids;
while (@pending) {
	@pending = grep { !$service->get($_)->{terminal} } @pending;
	die "Benchmark jobs timed out\n" if clock_gettime(CLOCK_MONOTONIC) - $start > 120;
	Wump::sleep(0.002) if @pending;
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
my @cpu_end = times;
my $cpu = ($cpu_end[0] - $cpu_start[0]) + ($cpu_end[1] - $cpu_start[1]);
for my $id (@ids) {
	my $job = $service->get($id);
	die "Benchmark job $id failed: " . ($job->{error} // $job->{state}) . "\n"
		unless $job->{state} eq 'completed' && same_result($job->{result}, $expected);
}
$service->shutdown;
die "Invalid benchmark interval\n" unless $elapsed > 0;

# This record contains numeric fields only. Encoding it directly keeps JSON
# serializer XS and HTTP work outside the measured job-service path.
printf "{\"execution_slots\":%d,\"workers\":%d,\"jobs\":%d,\"passes\":%d,\"wall_seconds\":%.9f,\"cpu_seconds\":%.6f,\"jobs_per_second\":%.6f,\"verified_jobs\":%d}\n",
	Wump::execution_slots(), $workers, $jobs, $passes, $elapsed, $cpu, $jobs / $elapsed, scalar @ids;
