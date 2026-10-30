use v5.42;
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use Cwd 'abs_path';
use IPC::Open3;
use File::Temp qw(tempdir tempfile);

@ARGV == 2 or die "Usage: perl $0 PRIVATE_PERL STOCK_PERL\n";
my ($private, $stock) = map { abs_path($_) } @ARGV;
sub run (@args) {
	my ($errors) = tempfile(UNLINK => 1);
	my ($input, $output);
	my $pid = open3($input, $output, '>&' . fileno($errors), $^X, 'bench/perl-baseline.pl', @args);
	close $input or die "Close child input: $!\n";
	my $stdout = do { local $/; <$output> };
	close $output or die "Close child output: $!\n";
	waitpid($pid, 0) == $pid or die "Wait for baseline: $!\n";
	my $status = $?;
	seek $errors, 0, 0 or die "Rewind errors: $!\n";
	my $stderr = do { local $/; <$errors> };
	return ($status, $stdout, $stderr);
}
my ($status, $output, $errors) = run($private, $stock, '--runs', 2, '--iterations', 98, '--jobs', 4);
is($status, 0, 'matched stock/fork and one/two/four-slot runs complete');
is($errors, '', 'successful comparison emits no diagnostics');
my @records = map { decode_json($_) } split /\n/, $output;
my @samples = grep { $_->{kind} eq 'sample' } @records;
my @summaries = grep { $_->{kind} eq 'summary' } @records;
is(scalar @samples, 10, 'all raw samples are retained');
is_deeply([map { $_->{variant} } @samples], [qw(stock fork wump-1 wump-2 wump-4 fork wump-1 wump-2 wump-4 stock)],
	'repetitions rotate the interleaved variant order');
is_deeply([map { $_->{variant} } @summaries], [qw(stock fork wump-1 wump-2 wump-4)], 'all comparison summaries are emitted');
is_deeply([map { $_->{execution_slots} } @summaries], [0, 0, 1, 2, 4], 'plain execution is distinct from runtime slots');
for my $sample (@samples) {
	is($sample->{iterations}, 98, 'each job runs identical work across the modulo boundary');
	is($sample->{verified_jobs}, 4, 'every job result and identity is verified');
	cmp_ok($sample->{process_seconds}, '>=', $sample->{wall_seconds}, 'process timing includes startup outside work timing');
	is($sample->{fork_config}{version}, $sample->{stock_config}{version}, 'comparison records matching Perl versions');
	like($sample->{source_revision}, qr/\A[0-9a-f]{40,64}\z/, 'comparison records its source revision');
}
for my $summary (@summaries) {
	my @wall = sort {$a <=> $b} map { $_->{wall_seconds} } grep { $_->{variant} eq $summary->{variant} } @samples;
	is($summary->{median_wall_seconds}, ($wall[0] + $wall[1]) / 2, 'even-run median includes both middle observations');
	cmp_ok($summary->{slowdown_vs_stock}, '>', 0, 'stock slowdown is reported without enforcing a performance threshold');
}
for my $option (qw(runs iterations jobs)) {
	($status, $output, $errors) = run($private, $stock, "--$option", 0);
	isnt($status, 0, "zero $option is rejected");
	is($output, '', 'invalid options emit no measurements');
	like($errors, qr/Invalid \Q$option\E/, 'option failure identifies the constraint');
}
($status, $output, $errors) = run($private, $private, '--runs', 1);
isnt($status, 0, 'a fork cannot masquerade as stock Perl');
like($errors, qr/Wrong interpreter role/, 'interpreter identity is checked before timing');
is($output, '', 'wrong interpreter roles emit no measurements');

my $scratch = tempdir(CLEANUP => 1);
my $config = $summaries[0]{stock_config};
for my $case (
	['version', {version => 'v5.44.0'}, qr/requires Perl v5\.42\.2/],
	['optimization', {optimize => '-O0'}, qr/build option mismatch: optimize/],
	['instrumentation', {ccflags => "$config->{ccflags} -fsanitize=undefined"}, qr/Instrumented builds/],
	['link instrumentation', {ldflags => "$config->{ldflags} -fsanitize=address"}, qr/Instrumented builds/],
) {
	my ($name, $overrides, $expected) = @$case;
	my $fake = "$scratch/stock $name";
	open my $script, '>', $fake or die "$fake: $!\n";
	print {$script} "#!$^X\nprint <<'CONFIG';\n", encode_json({%$config, %$overrides}), "\nCONFIG\n"
		or die "Write probe fixture: $!\n";
	close $script or die "Close probe fixture: $!\n";
	chmod 0755, $fake or die "Make probe executable: $!\n";
	($status, $output, $errors) = run($private, $fake, '--runs', 1);
	isnt($status, 0, "$name mismatch fails before benchmark execution");
	is($output, '', 'incompatible configuration emits no measurements');
	like($errors, $expected, 'failure identifies the incompatible configuration');
}
{
	my $fake = "$scratch/invalid worker";
	open my $script, '>', $fake or die "$fake: $!\n";
	# A valid fork probe followed by the same JSON in place of a worker result
	# must fail the run instead of publishing a misleading comparison summary.
	print {$script} "#!$^X\nprint <<'CONFIG';\n", encode_json($summaries[0]{fork_config}), "\nCONFIG\n"
		or die "Write worker fixture: $!\n";
	close $script or die "Close worker fixture: $!\n";
	chmod 0755, $fake or die "Make worker executable: $!\n";
	($status, $output, $errors) = run($fake, $stock, '--runs', 1, '--iterations', 98, '--jobs', 4);
	isnt($status, 0, 'invalid child measurements fail the comparison');
	like($errors, qr/Invalid baseline field/, 'failure identifies an invalid measurement');
	unlike($output, qr/"kind":"summary"/, 'an incomplete run emits no comparison summary');
}
done_testing;
