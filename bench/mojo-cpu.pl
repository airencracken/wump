#!/usr/bin/env perl
use v5.42;
use strict;
use warnings;
use FindBin;
use Cwd 'abs_path';
use File::Basename 'dirname';
use Getopt::Long 'GetOptions';
use JSON::PP qw(decode_json encode_json);
use Time::HiRes 'time';

my $usage = "Usage: perl $0 PRIVATE_PERL [--runs 3] [--jobs 8] [--passes 20] [--workers 4]\n";
my $private = abs_path(shift // die $usage);
die "Private Perl is not executable\n" unless defined($private) && -x $private;
my %options = (runs => 3, jobs => 8, passes => 20, workers => 4);
GetOptions(\%options, 'runs=i', 'jobs=i', 'passes=i', 'workers=i') && !@ARGV or die $usage;
for my $setting ([runs => 20], [jobs => 256], [passes => 100], [workers => 64]) {
	my ($key, $max) = @$setting;
	die "Invalid $key\n" unless $options{$key} >= 1 && $options{$key} <= $max;
}
my $root = abs_path("$FindBin::Bin/..");
my $directory = dirname($private);
my @interpreter = ($private, "-I$directory/lib");
open my $version_pipe, '-|', @interpreter, '-e', 'print $^V' or die "Read Perl version: $!\n";
my $version = do { local $/; <$version_pipe> };
close $version_pipe or die "Perl version probe failed: $?\n";
die "Invalid Perl version response\n" unless $version =~ /\Av\d+\.\d+\.\d+\z/;
open my $revision_pipe, '-|', 'git', '-C', $root, 'rev-parse', 'HEAD' or die "Read revision: $!\n";
chomp(my $revision = <$revision_pipe> // '');
close $revision_pipe or die "Git revision probe failed: $?\n";
open my $status_pipe, '-|', 'git', '-C', $root, 'status', '--porcelain', '--untracked-files=normal'
	or die "Read source status: $!\n";
my $dirty = do { local $/; <$status_pipe> };
close $status_pipe or die "Git status probe failed: $?\n";
my %metadata = (private_perl => $private, perl_version => $version, source_revision => $revision,
	source_dirty => $dirty ? JSON::PP::true : JSON::PP::false, fixture => 'unicode-log-v1');

sub median (@values) {
	my @sorted = sort {$a <=> $b} @values;
	return @sorted % 2 ? $sorted[int(@sorted / 2)]
		: ($sorted[@sorted / 2 - 1] + $sorted[@sorted / 2]) / 2;
}

my $baseline;
for my $slots (1, 2, 4) {
	my @samples;
	for my $sample (1..$options{runs}) {
		local $ENV{WUMPPROCS} = $slots;
		my $started = time;
		open my $child, '-|', @interpreter, "$FindBin::Bin/mojo-jobs.pl", @options{qw(jobs passes workers)}
			or die "Start benchmark: $!\n";
		my $output = do { local $/; <$child> };
		close $child;
		my $status = $?;
		my $process = time - $started;
		die "Benchmark child failed (wait status $status):\n$output" if $status;
		my $result = eval { decode_json($output) };
		die "Invalid benchmark record: $@\n$output" unless ref($result) eq 'HASH';
		for my $field (qw(execution_slots workers jobs passes verified_jobs wall_seconds cpu_seconds jobs_per_second)) {
			die "Invalid benchmark field $field\n" unless defined($result->{$field})
				&& !ref($result->{$field}) && $result->{$field} =~ /\A\d+(?:\.\d+)?\z/;
		}
		die "Benchmark configuration or verification changed\n" unless $result->{execution_slots} == $slots
			&& $result->{jobs} == $options{jobs} && $result->{passes} == $options{passes}
			&& $result->{workers} == $options{workers} && $result->{verified_jobs} == $options{jobs}
			&& $result->{wall_seconds} > 0;
		push @samples, $result;
		print encode_json({kind => 'sample', sample => $sample, %$result, %metadata,
			process_seconds => $process}), "\n";
	}
	my $wall = median(map { $_->{wall_seconds} } @samples);
	$baseline //= $wall;
	print encode_json({kind => 'summary', %metadata, execution_slots => $slots,
		%options, median_wall_seconds => $wall, median_cpu_seconds => median(map { $_->{cpu_seconds} } @samples),
		jobs_per_second => $options{jobs} / $wall, speedup => $baseline / $wall}), "\n";
}
