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

my $usage = "Usage: perl $0 PRIVATE_PERL STOCK_PERL [--runs 5] [--iterations 500000] [--jobs 8] [--max-slots 4|8]\n";
@ARGV >= 2 or die $usage;
my ($private, $stock) = splice @ARGV, 0, 2;
my %options = (runs => 5, iterations => 500_000, jobs => 8, max_slots => 4);
GetOptions(\%options, 'runs=i', 'iterations=i', 'jobs=i', 'max_slots|max-slots=i') && !@ARGV or die $usage;
die "Invalid max-slots (expected 4 or 8)\n" unless $options{max_slots} == 4 || $options{max_slots} == 8;
for my $setting ([runs => 20], [iterations => 50_000_000], [jobs => 256]) {
	my ($key, $max) = @$setting;
	die "Invalid $key\n" unless $options{$key} >= 1 && $options{$key} <= $max;
}
for ($private, $stock) {
	$_ = abs_path($_);
	die "Perl is not executable\n" unless defined($_) && -x $_;
}
local $ENV{PERL5OPT};
delete $ENV{PERL5OPT};
my $root = abs_path("$FindBin::Bin/..");

sub capture (@command) {
	open my $child, '-|', @command or die "Start $command[0]: $!\n";
	my $output = do { local $/; <$child> };
	close $child;
	die "Child failed (wait status $?):\n$output" if $?;
	return $output;
}
sub invocation ($perl) { return ($perl, '-I' . dirname($perl) . '/lib') }
sub configuration ($perl, $wump) {
	my $config = decode_json(capture(invocation($perl), '-MConfig', '-MJSON::PP', '-e', q{
		print JSON::PP::encode_json({version => "$^V", wump => defined(&Wump::_enable) ? 1 : 0,
			map { $_ => $Config::Config{$_} // '' }
			qw(cc gccversion ccflags ldflags lddlflags optimize archname usemultiplicity useithreads use64bitall)});
	}));
	die "Invalid baseline configuration record\n" unless ref($config) eq 'HASH';
	for my $key (qw(version wump cc gccversion ccflags ldflags lddlflags optimize archname usemultiplicity useithreads use64bitall)) {
		die "Invalid baseline configuration field $key\n" unless defined($config->{$key}) && !ref($config->{$key});
	}
	die "Invalid baseline interpreter role\n" unless $config->{wump} =~ /\A[01]\z/;
	die "Baseline requires Perl v5.42.2\n" unless $config->{version} eq 'v5.42.2';
	die "Wrong interpreter role for $perl\n" unless $config->{wump} == $wump;
	die "Instrumented builds are not performance baselines\n"
		if join(' ', @{$config}{qw(ccflags ldflags lddlflags)}) =~ /-fsanitize|--coverage|-fprofile/;
	return $config;
}
my $fork_config = configuration($private, 1);
my $stock_config = configuration($stock, 0);
for my $key (qw(cc gccversion ccflags ldflags lddlflags optimize archname usemultiplicity useithreads use64bitall)) {
	die "Baseline build option mismatch: $key\n" unless $fork_config->{$key} eq $stock_config->{$key};
}
my $revision = capture('git', '-C', $root, 'rev-parse', 'HEAD');
chomp $revision;
my $dirty = capture('git', '-C', $root, 'status', '--porcelain', '--untracked-files=normal');
my $cpu_model = '';
if (open my $cpuinfo, '<', '/proc/cpuinfo') {
	while (<$cpuinfo>) { if (/\Amodel name\s*:\s*(.+)/) { $cpu_model = $1; last } }
	close $cpuinfo or die "Close CPU information: $!\n";
}
my %metadata = (source_revision => $revision, source_dirty => $dirty ? JSON::PP::true : JSON::PP::false,
	private_perl => $private, stock_perl => $stock, fork_config => $fork_config,
	stock_config => $stock_config, cpu_model => $cpu_model, fixture => 'integer-reduction-v1');
my @variants = (
	['stock', $stock, 'plain', 0], ['fork', $private, 'plain', 0],
	map { ["wump-$_", $private, 'wump', $_] } (1, 2, 4),
);
push @variants, ['wump-8', $private, 'wump', 8] if $options{max_slots} == 8;
my %samples;
# Rotate interleaved runs so each variant takes a different position in a
# batch. Process startup is measured separately from compute work.
for my $sample (1..$options{runs}) {
	for my $offset (0..$#variants) {
		my ($variant, $perl, $mode, $slots) = @{$variants[($offset + $sample - 1) % @variants]};
		local $ENV{WUMPPROCS} = $slots || 1;
		local $ENV{WUMP_BASELINE_MODE} = $mode;
		my $started = time;
		my $result = decode_json(capture(invocation($perl), "$FindBin::Bin/perl-baseline-worker.pl",
			$mode, @options{qw(iterations jobs)}));
		my $process = time - $started;
		for my $field (qw(execution_slots iterations jobs verified_jobs wall_seconds cpu_seconds)) {
			die "Invalid baseline field $field\n" unless defined($result->{$field}) && !ref($result->{$field})
				&& $result->{$field} =~ /\A\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i;
		}
		die "Baseline configuration or verification changed\n" unless $result->{execution_slots} == $slots
			&& $result->{iterations} == $options{iterations} && $result->{jobs} == $options{jobs}
			&& $result->{verified_jobs} == $options{jobs} && $result->{wall_seconds} > 0;
		push @{$samples{$variant}}, $result;
		print encode_json({kind => 'sample', variant => $variant, sample => $sample, %$result,
			%metadata, process_seconds => $process}), "\n";
	}
}
sub median (@values) {
	my @sorted = sort {$a <=> $b} @values;
	return @sorted % 2 ? $sorted[int(@sorted / 2)] : ($sorted[@sorted / 2 - 1] + $sorted[@sorted / 2]) / 2;
}
my $stock_wall = median(map { $_->{wall_seconds} } @{$samples{stock}});
my $wump_wall = median(map { $_->{wall_seconds} } @{$samples{'wump-1'}});
for my $entry (@variants) {
	my ($variant, undef, undef, $slots) = @$entry;
	my $wall = median(map { $_->{wall_seconds} } @{$samples{$variant}});
	print encode_json({kind => 'summary', variant => $variant, execution_slots => $slots, %options, %metadata,
		median_wall_seconds => $wall, median_cpu_seconds => median(map { $_->{cpu_seconds} } @{$samples{$variant}}),
		slowdown_vs_stock => $wall / $stock_wall, speedup_vs_wump_one => $wump_wall / $wall}), "\n";
}
