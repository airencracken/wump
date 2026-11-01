#!/usr/bin/env perl
use v5.42;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Wump::BenchMatrix qw(operations variants primitive validate_result validate_metadata validate_capture report);
use Cwd 'abs_path';
use File::Basename qw(dirname basename);
use File::Temp qw(tempfile);
use Getopt::Long 'GetOptions';
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use IPC::Open3;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my $usage = "usage: perl $0 WUMP_PERL STOCK_PERL GO_WORKER --output FILE [--runs 5 --iterations 50000 --jobs 8]\n";
my %opts = (runs => 5, iterations => 50000, jobs => 8);
GetOptions(\%opts, 'output=s', 'runs=i', 'iterations=i', 'jobs=i') && @ARGV == 3 && defined($opts{output}) or die $usage;
for my $spec ([runs => 20], [iterations => 2000000], [jobs => 64]) {
	my ($key, $max) = @$spec;
	$opts{$key} >= 1 && $opts{$key} <= $max or die "invalid $key\n";
}
my ($wump, $stock, $go) = map {my $p = abs_path($_); defined($p) && -f $p && -x $p or die "executable unavailable: $_\n"; $p} @ARGV;
my $destination = abs_path(dirname($opts{output})) // die "output directory does not exist\n";
my $output_path = "$destination/" . basename($opts{output});
!-e $output_path || -f $output_path or die "output must be a regular file\n";
for my $binary ($wump, $stock, $go) { $output_path ne $binary or die "output would replace an executable\n" }
my $root = abs_path("$FindBin::Bin/..");
for my $key (qw(PERL5OPT PERL5LIB PERLLIB PERL_UNICODE PERL_HASH_SEED PERL_PERTURB_KEYS PERLIO GODEBUG GOMAXPROCS GOFLAGS GOGC GOMEMLIMIT GORACE)) { delete $ENV{$key} }
local $ENV{LC_ALL} = 'C';
local $ENV{LANG} = 'C';

sub contents ($path) {
	open my $in, '<', $path or die "$path: $!\n";
	my $value = do {local $/; <$in>};
	close $in or die $!;
	return $value;
}
sub capture (@command) {
	my ($errors) = tempfile(UNLINK => 1);
	my ($input, $output);
	my $start = clock_gettime(CLOCK_MONOTONIC);
	my $pid = open3($input, $output, '>&' . fileno($errors), 'timeout', '90s', @command);
	close $input or die $!;
	my $text = do {local $/; <$output>};
	close $output or die $!;
	waitpid($pid, 0) == $pid or die $!;
	my $status = $?;
	my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
	seek $errors, 0, 0 or die $!;
	my $diagnostics = do {local $/; <$errors>};
	die "command failed ($status): @command\n$diagnostics$text" if $status;
	die "unexpected worker diagnostics: $diagnostics" if length($diagnostics);
	return ($text, $elapsed);
}
sub perl_command ($binary) { return ($binary, '-I' . dirname($binary) . '/lib') }
my %binaries;
for my $spec ([wump => $wump], [stock => $stock], [go => $go]) {
	my ($role, $binary) = @$spec;
	my ($probe) = $role eq 'go' ? capture($binary, '--identify') : capture(perl_command($binary), '-MConfig', '-MJSON::PP', '-e',
		q{print JSON::PP::encode_json({version => "$^V", wump => defined(&Wump::_enable) ? 1 : 0,
		map {$_ => $Config::Config{$_} // ''} qw(archname cc gccversion ccflags ldflags lddlflags optimize usemultiplicity useithreads use64bitall)})});
	$binaries{$role} = {path => $binary, sha256 => sha256_hex(contents($binary)), config => JSON::PP::decode_json($probe)};
}
my ($revision) = capture('git', '-C', $root, 'rev-parse', 'HEAD');
chomp $revision;
my ($dirty) = capture('git', '-C', $root, 'status', '--porcelain', '--untracked-files=normal');
my $cpu = contents('/proc/cpuinfo');
$cpu =~ /^model name\s*:\s*(.+)$/m or die "CPU model unavailable\n";
my $model = $1;
my $status = contents('/proc/self/status');
$status =~ /^Cpus_allowed_list:\s*(\S+)/m or die "CPU affinity unavailable\n";
my $affinity = $1;
my ($kernel) = capture('uname', '-srmo');
chomp $kernel;
my @fixture_files = ("$FindBin::Bin/matrix.pl", "$FindBin::Bin/matrix-worker.pl", "$FindBin::Bin/matrix-worker.go", "$FindBin::Bin/lib/Wump/BenchMatrix.pm");
for my $fixture (@fixture_files) { $output_path ne abs_path($fixture) or die "output would replace a benchmark source\n" }
my $capture = {
	schema => 'wump-operation-matrix-v3', complete => JSON::PP::true,
	parameters => {map {$_ => $opts{$_}} qw(runs iterations jobs)},
	machine => {cpu_model => $model, affinity => $affinity, kernel => $kernel},
	source => {revision => $revision, dirty => $dirty ? JSON::PP::true : JSON::PP::false,
		fixture_sha256 => sha256_hex(join '', map {contents($_)} @fixture_files)},
	binaries => \%binaries, cells => [],
};
my @variants = variants();
my %cells;
for my $op (operations()) {
	for my $variant (@variants) {
		my $cell = {operation => $op, variant => $variant, samples => []};
		$cells{"$op:$variant"} = $cell;
		push @{$capture->{cells}}, $cell;
	}
}
validate_metadata($capture);

my $sequence = 0;
for my $run (1..$opts{runs}) {
	for my $op (operations()) {
		for my $offset (0..$#variants) {
			my $variant = $variants[($offset + $run - 1) % @variants];
			my $slots = $variant =~ /-(1|2|4)\z/ ? 0 + $1 : 0;
			my $result;
			if (primitive($op) && (!$slots || $variant =~ /\A(?:fork|ithreads)-/)) {
				$result = {status => 'unsupported', reason => 'no coroutine runtime in this mode', operation => $op,
					iterations => $opts{iterations}, jobs => $opts{jobs}, slots => $slots};
			} else {
				local $ENV{WUMPPROCS} = $slots || 1;
				local $ENV{WUMP_MATRIX_MODE} = $variant =~ /\A(wump|fork|ithreads)-[124]\z/ ? $1 : 'plain';
				local $ENV{WUMP_MATRIX_SLOTS} = $slots;
				my @command = $variant =~ /\Ago-/ ? ($go, $op, @opts{qw(iterations jobs)}, $slots)
					: (perl_command($variant eq 'stock' || $variant =~ /\A(?:fork|ithreads)-/ ? $stock : $wump), "$FindBin::Bin/matrix-worker.pl", $op, @opts{qw(iterations jobs)});
				my ($output, $elapsed) = capture(@command);
				$result = eval {JSON::PP::decode_json($output)};
				ref($result) eq 'HASH' or die "invalid worker JSON: $op $variant\n";
				$result->{process_seconds} = $elapsed;
			}
			validate_result($result, $op, $variant, @opts{qw(iterations jobs)});
			push @{$cells{"$op:$variant"}{samples}}, {%$result, run => $run, sequence => ++$sequence};
		}
	}
}
validate_capture($capture);
for my $binary (values %binaries) {
	sha256_hex(contents($binary->{path})) eq $binary->{sha256} or die "binary changed during capture\n";
}
sha256_hex(join '', map {contents($_)} @fixture_files) eq $capture->{source}{fixture_sha256} or die "fixtures changed during capture\n";
my ($out, $temporary) = tempfile('.matrix-XXXXXX', DIR => $destination, UNLINK => 1);
print {$out} JSON::PP->new->canonical->encode($capture), "\n" or die "write matrix: $!\n";
close $out or die "close matrix: $!\n";
rename $temporary, $output_path or die "publish matrix: $!\n";
print report($capture);
