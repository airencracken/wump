#!/usr/bin/env perl
use v5.42;
use strict;
use warnings;
use Getopt::Long 'GetOptions';
use JSON::PP qw(decode_json);

my $usage = "Usage: perl $0 BEFORE.jsonl AFTER.jsonl [--max-regression 10]\n";
my $limit = 10;
GetOptions('max-regression=f' => \$limit) && @ARGV == 2 or die $usage;
die "Invalid regression percentage\n" unless $limit =~ /\A\d+(?:\.\d+)?\z/ && $limit <= 100;
my @variants = qw(stock fork wump-1 wump-2 wump-4);
my %slots = (stock => 0, fork => 0, 'wump-1' => 1, 'wump-2' => 2, 'wump-4' => 4);
my $json = JSON::PP->new->canonical;

sub positive ($value) {
	return defined($value) && !ref($value) && $value =~ /\A\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i
		&& $value > 0 && $value < 1e100;
}
sub median (@values) {
	my @sorted = sort {$a <=> $b} @values;
	return @sorted % 2 ? $sorted[int(@sorted / 2)] : ($sorted[@sorted / 2 - 1] + $sorted[@sorted / 2]) / 2;
}
sub capture ($path) {
	open my $input, '<', $path or die "$path: $!\n";
	my (%samples, %summaries, $metadata, $identity);
	while (my $line = <$input>) {
		my $record = eval { decode_json($line) };
		die "$path: invalid JSON record\n" unless ref($record) eq 'HASH';
		my $variant = $record->{variant} // '';
		die "$path: unknown execution variant\n" unless exists $slots{$variant};
		die "$path: invalid execution slots\n" unless defined($record->{execution_slots})
			&& !ref($record->{execution_slots}) && $record->{execution_slots} eq "$slots{$variant}";
		die "$path: dirty or missing source state\n" unless JSON::PP::is_bool($record->{source_dirty}) && !$record->{source_dirty};
		die "$path: invalid source revision\n" unless !ref($record->{source_revision})
			&& ($record->{source_revision} // '') =~ /\A[0-9a-f]{40,64}\z/;
		for my $field (qw(iterations jobs)) {
			die "$path: invalid $field\n" unless !ref($record->{$field}) && ($record->{$field} // '') =~ /\A[1-9][0-9]*\z/;
		}
		die "$path: invalid fixture or CPU model\n" unless ($record->{fixture} // '') eq 'integer-reduction-v1'
			&& defined($record->{cpu_model}) && !ref($record->{cpu_model}) && length($record->{cpu_model});
		for my $role (qw(fork stock)) {
			my $config = $record->{"${role}_config"};
			die "$path: missing $role build configuration\n" unless ref($config) eq 'HASH';
			for my $field (qw(version wump cc gccversion ccflags ldflags lddlflags optimize archname usemultiplicity useithreads use64bitall)) {
				die "$path: invalid build field $role/$field\n" unless defined($config->{$field}) && !ref($config->{$field});
			}
			die "$path: incompatible interpreter role or version\n" unless $config->{version} eq 'v5.42.2'
				&& $config->{wump} eq ($role eq 'fork' ? '1' : '0');
			die "$path: instrumented build\n" if join(' ', @{$config}{qw(ccflags ldflags lddlflags)}) =~ /-fsanitize|--coverage|-fprofile/;
		}
		for my $field (qw(version cc gccversion ccflags ldflags lddlflags optimize archname usemultiplicity useithreads use64bitall)) {
			die "$path: stock/fork build mismatch: $field\n" unless $record->{fork_config}{$field} eq $record->{stock_config}{$field};
		}
		my $current = {map { $_ => $record->{$_} }
			qw(fixture cpu_model fork_config stock_config iterations jobs)};
		my $current_identity = $json->encode({%$current, source_revision => $record->{source_revision}});
		$metadata //= $current;
		$identity //= $current_identity;
		die "$path: mixed configurations or revisions\n" unless $identity eq $current_identity;
		if (($record->{kind} // '') eq 'sample') {
			my $sample = $record->{sample} // '';
			die "$path: invalid or duplicate sample\n" unless !ref($sample) && $sample =~ /\A[1-9][0-9]*\z/
				&& !exists $samples{$variant}{$sample};
			die "$path: unverified jobs\n" unless defined($record->{verified_jobs})
				&& $record->{verified_jobs} eq "$record->{jobs}";
			die "$path: invalid timing\n" unless positive($record->{wall_seconds}) && positive($record->{process_seconds})
				&& $record->{process_seconds} >= $record->{wall_seconds};
			$samples{$variant}{$sample} = $record;
		} elsif (($record->{kind} // '') eq 'summary') {
			die "$path: duplicate summary\n" if exists $summaries{$variant};
			$summaries{$variant} = $record;
		} else { die "$path: unknown record kind\n" }
	}
	close $input or die "$path: $!\n";
	my (%timings, $runs);
	for my $variant (@variants) {
		my $summary = $summaries{$variant} // die "$path: missing $variant summary\n";
		my $count = $summary->{runs} // '';
		die "$path: at least three runs required\n" unless !ref($count) && $count =~ /\A[1-9][0-9]*\z/ && $count >= 3 && $count <= 20;
		$runs //= $count;
		die "$path: inconsistent run counts\n" unless $runs == $count;
		my $samples = $samples{$variant} // {};
		die "$path: incomplete $variant samples\n" unless keys(%$samples) == $count && !grep { !exists $samples->{$_} } 1..$count;
		$timings{$variant}{work} = median(map { $_->{wall_seconds} } values %$samples);
		$timings{$variant}{process} = median(map { $_->{process_seconds} } values %$samples);
		my $reported = $summary->{median_wall_seconds};
		die "$path: inconsistent median\n" unless positive($reported)
			&& abs($reported - $timings{$variant}{work}) <= $timings{$variant}{work} * 1e-9;
	}
	return {metadata => {%$metadata, runs => $runs}, timings => \%timings};
}

my ($before, $after) = map { capture($_) } @ARGV;
die "Cannot compare different workloads, machines or build configurations\n"
	unless $json->encode($before->{metadata}) eq $json->encode($after->{metadata});
my $failed = 0;
for my $variant (@variants[1..$#variants]) {
	for my $metric (qw(work process)) {
		my $old = $before->{timings}{$variant}{$metric} / $before->{timings}{stock}{$metric};
		my $new = $after->{timings}{$variant}{$metric} / $after->{timings}{stock}{$metric};
		my $change = 100 * ($new / $old - 1);
		my $regressed = $change > $limit + 1e-9;
		$failed ||= $regressed;
		printf "%s %s %s: %+.2f%%, %.2fx stock (limit +%.2f%%)\n",
			$regressed ? 'FAIL' : 'PASS', $variant, $metric, $change, $new, $limit;
	}
}
exit($failed ? 1 : 0);
