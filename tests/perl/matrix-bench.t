use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'bench/lib';
use Wump::BenchMatrix qw(load_capture validate_result operations variants);
use File::Temp qw(tempdir tempfile);
use File::Basename 'dirname';
use Cwd 'abs_path';
use JSON::PP;
use IPC::Open3;

@ARGV == 3 or die "usage: matrix-bench.t WUMP_PERL STOCK_PERL GO_WORKER\n";
my ($wump, $stock, $go) = map {abs_path($_) // die "$!"} @ARGV;
my $scratch = tempdir(CLEANUP => 1);
sub run (@command) {
	my ($errors) = tempfile(UNLINK => 1);
	my ($in, $out);
	my $pid = open3($in, $out, '>&' . fileno($errors), 'timeout', '120s', @command);
	close $in or die $!;
	my $text = do {local $/; <$out>};
	close $out or die $!;
	waitpid($pid, 0) == $pid or die $!;
	my $status = $?;
	seek $errors, 0, 0 or die $!;
	my $diagnostics = do {local $/; <$errors>};
	return ($status, $text, $diagnostics);
}
sub save ($path, $value) {
	open my $out, '>', $path or die $!;
	print {$out} JSON::PP->new->canonical->encode($value) or die $!;
	close $out or die $!;
}
sub read_all ($path) {
	open my $in, '<', $path or die $!;
	my $text = do {local $/; <$in>};
	close $in or die $!;
	return $text;
}
my $path = "$scratch/complete matrix.json";
my ($status, $text, $errors) = run($^X, 'bench/matrix.pl', $wump, $stock, $go,
	'--output', $path, '--runs', 3, '--iterations', 98, '--jobs', 4);
is($status, 0, 'all languages and slot counts complete across the 97-value boundary');
is($errors, '', 'successful capture emits no diagnostics');
BAIL_OUT($errors) if $status;
my $capture = load_capture($path);
is(scalar @{$capture->{cells}}, 88, 'all eleven operations and eight variants are present');
is(scalar(map {@{$_->{samples}}} @{$capture->{cells}}), 264, 'all three raw runs are retained');
like($text, qr/Stock Perl.*Wump unused.*Go 4/, 'capture prints the readable matrix');
like($text, qr/parallel XS admission: utf8::encode|\| json \|/, 'JSON behavior remains visible');
for my $spec (['stock', 1, 1], ['wump-unused', 1, 2], ['stock', 2, 96], ['wump-unused', 2, 89]) {
	my ($variant, $run, $sequence) = @$spec;
	my ($cell) = grep {$_->{operation} eq 'arithmetic' && $_->{variant} eq $variant} @{$capture->{cells}};
	is($cell->{samples}[$run - 1]{sequence}, $sequence, 'execution order rotates between raw runs');
}
for my $cell (@{$capture->{cells}}) {
	is(scalar @{$cell->{samples}}, 3, "$cell->{operation}/$cell->{variant} retains every repetition");
}
for my $op (qw(yield spawn channel)) {
	my ($cell) = grep {$_->{operation} eq $op && $_->{variant} eq 'stock'} @{$capture->{cells}};
	is($cell->{samples}[0]{status}, 'unsupported', "$op is not fabricated for stock Perl");
}
($status, $text, $errors) = run($^X, 'bench/matrix-report.pl', $path, '--metric', 'process');
is($status, 0, 'saved capture can be reported without running workloads');
like($text, qr/whole-process milliseconds/, 'report selects process units explicitly');

# These temporary files are protocol tests, not accepted timing evidence.
my $clean = decode_json(encode_json($capture));
$clean->{source}{dirty} = JSON::PP::false;
my $before = "$scratch/synthetic clean before.json";
save($before, $clean);
($status, $text, $errors) = run($^X, 'bench/matrix-check.pl', $before, $before);
is($status, 0, 'CLI checker accepts an identical validated protocol fixture');
my ($changed) = grep {$_->{operation} eq 'arithmetic' && $_->{variant} eq 'wump-1'} @{$clean->{cells}};
$_->{wall_seconds} *= 2 for @{$changed->{samples}};
my $after = "$scratch/regression.json";
save($after, $clean);
($status, $text, $errors) = run($^X, 'bench/matrix-check.pl', $before, $after);
is($status, 256, 'CLI checker returns failure for a per-cell regression');
like($text, qr/FAIL arithmetic wump-1 work/, 'CLI names the regressed cell');

for my $n (1, 97, 1025) {
	for my $variant (qw(wump-1 wump-4 go-1 go-4)) {
		my $slots = $variant =~ /-(\d)$/ ? $1 : die;
		local $ENV{WUMP_MATRIX_MODE} = 'wump';
		local $ENV{WUMPPROCS} = $slots;
		my @command = $variant =~ /^go/ ? ($go, 'spawn', $n, 1, $slots)
			: ($wump, '-I' . dirname($wump) . '/lib', 'bench/matrix-worker.pl', 'spawn', $n, 1);
		($status, $text, $errors) = run(@command);
		is($status, 0, "$variant spawn handles $n operations, including cohort overflow");
		my $result = eval {decode_json($text)};
		ok(eval {validate_result($result, 'spawn', $variant, $n, 1); 1}, 'boundary result passes independent identity/count/checksum validation') or diag($@, $errors);
	}
}

my $sentinel = "$scratch/preserved.json";
for my $option (qw(runs iterations jobs)) {
	save($sentinel, {preserve => 1});
	my $old = read_all($sentinel);
	($status, $text, $errors) = run($^X, 'bench/matrix.pl', $wump, $stock, $go, '--output', $sentinel, "--$option", 0);
	isnt($status, 0, "zero $option is rejected");
	is(read_all($sentinel), $old, 'invalid options preserve the previous capture');
}
($status, $text, $errors) = run($^X, 'bench/matrix.pl', $wump, $wump, $go, '--output', $sentinel, '--runs', 1);
isnt($status, 0, 'Wump cannot masquerade as stock Perl');
like($errors, qr/wrong Perl interpreter role/, 'role failure is diagnosed before timing');

for my $failure ('result', 'exit', 'diagnostics') {
	my $fake = "$scratch/fake Go $failure";
	open my $out, '>', $fake or die $!;
	print {$out} "#!$^X\nif (\@ARGV == 1 && \$ARGV[0] eq '--identify') { print <<'IDENTITY';\n",
		encode_json($capture->{binaries}{go}{config}), "\nIDENTITY\nexit; }\n",
		$failure eq 'exit' ? "exit 17;\n" : $failure eq 'diagnostics' ? "warn qq(unexpected diagnostic\\n); print qq({}\\n);\n" : "print qq({}\\n);\n" or die $!;
	close $out or die $!;
	chmod 0755, $fake or die $!;
	save($sentinel, {preserve => 1});
	my $old = read_all($sentinel);
	($status, $text, $errors) = run($^X, 'bench/matrix.pl', $wump, $stock, $fake,
		'--output', $sentinel, '--runs', 1, '--iterations', 1, '--jobs', 1);
	isnt($status, 0, "worker $failure fails the capture");
	is(read_all($sentinel), $old, 'failed capture is atomic and preserves existing evidence');
	is($text, '', 'a failed capture publishes no success report');
}
done_testing;
