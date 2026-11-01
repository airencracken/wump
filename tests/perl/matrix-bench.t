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
is($capture->{schema}, 'wump-operation-matrix-v3', 'public-syntax capture records the new fixture version');
for my $variant (qw(wump-1 wump-2 wump-4)) {
	my ($cell) = grep {$_->{operation} eq 'spawn' && $_->{variant} eq $variant} @{$capture->{cells}};
	is_deeply($cell->{samples}[0]{native_ops}, [qw(wumpact wumpchan wumpyield)],
		"$variant verifies the worker's compiled public operations");
	is_deeply($cell->{samples}[0]{native_methods}, [qw(Wump::Channel::close Wump::Channel::recv Wump::Channel::send)],
		"$variant verifies the resolved native channel entries");
}
is(scalar @{$capture->{cells}}, 154, 'all eleven operations and fourteen variants are present');
is(scalar(map {@{$_->{samples}}} @{$capture->{cells}}), 462, 'all three raw runs are retained');
like($text, qr/Stock Perl.*Wump unused.*Go 4/, 'capture prints the readable matrix');
like($text, qr/parallel XS admission: utf8::encode|\| json \|/, 'JSON behavior remains visible');
for my $spec (['stock', 1, 1], ['wump-unused', 1, 8], ['stock', 2, 168], ['wump-unused', 2, 161]) {
	my ($variant, $run, $sequence) = @$spec;
	my ($cell) = grep {$_->{operation} eq 'arithmetic' && $_->{variant} eq $variant} @{$capture->{cells}};
	is($cell->{samples}[$run - 1]{sequence}, $sequence, 'execution order rotates between raw runs');
}
for my $cell (@{$capture->{cells}}) {
	is(scalar @{$cell->{samples}}, 3, "$cell->{operation}/$cell->{variant} retains every repetition");
}
for my $op (qw(yield spawn channel)) {
	for my $variant (qw(stock fork-1 fork-2 fork-4 ithreads-1 ithreads-2 ithreads-4)) {
		my ($cell) = grep {$_->{operation} eq $op && $_->{variant} eq $variant} @{$capture->{cells}};
		is($cell->{samples}[0]{status}, 'unsupported', "$op is not fabricated for $variant");
	}
}
for my $mode (qw(fork ithreads)) {
	for my $jobs (1, 7) {
		local $ENV{WUMP_MATRIX_MODE} = $mode;
		local $ENV{WUMP_MATRIX_SLOTS} = 4;
		($status, $text, $errors) = run($stock, '-I' . dirname($stock) . '/lib', 'bench/matrix-worker.pl', 'arrays', 98, $jobs);
		is($status, 0, "$mode handles $jobs jobs with four worker slots");
		is($errors, '', 'process/thread completion produces no diagnostics');
		ok(eval {validate_result(decode_json($text), 'arrays', "$mode-4", 98, $jobs); 1}, 'uneven partitions and idle slots retain every unique job') or diag($@);
	}
}
for my $failure (qw(fork-create fork-child ithreads-create)) {
	my $mode = $failure =~ /^fork/ ? 'fork' : 'ithreads';
	local $ENV{WUMP_MATRIX_MODE} = $mode;
	local $ENV{WUMP_MATRIX_SLOTS} = 4;
	my $inject = $failure eq 'fork-create' ? q{
		BEGIN { my $calls = 0; *CORE::GLOBAL::fork = sub {
			if (++$calls == 2) { $! = 11; return undef }
			return CORE::fork();
		} }
	} : $failure eq 'fork-child' ? q{
		BEGIN { *CORE::GLOBAL::fork = sub {
			my $pid = CORE::fork();
			POSIX::_exit(17) if defined($pid) && !$pid;
			return $pid;
		} }
	} : q{
		BEGIN {
			require threads;
			my $create = \&threads::create;
			my $calls = 0;
			no warnings 'redefine';
			*threads::create = sub { die "injected thread creation failure\n" if ++$calls == 2; goto &$create };
		}
	};
	my $program = $inject . q{
		my $file = shift;
		do $file;
		my $error = $@;
		die "failure was swallowed\n" unless $error =~ /fork:|fork worker failed|injected thread creation failure/;
		die "unreaped child\n" if waitpid(-1, 1) != -1;
		die "unjoined thread\n" if $ENV{WUMP_MATRIX_MODE} eq 'ithreads' && threads->list();
		print "clean failure\n";
	};
	($status, $text, $errors) = run($stock, '-I' . dirname($stock) . '/lib', '-e', $program,
		abs_path('bench/matrix-worker.pl'), 'arrays', 98, 7);
	is($status, 0, "$failure propagates after reaping/joining started workers") or diag($errors);
	is($text, "clean failure\n", 'failed worker publishes no success result');
	is($errors, '', 'failure cleanup emits no leaked-worker diagnostics');
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
for my $op (qw(yield spawn chan sleep)) {
	for my $mode (qw(public xs native)) {
		for my $n (1, 1025) {
			for my $slots (1, 4) {
				local $ENV{WUMPPROCS} = $slots;
				($status, $text, $errors) = run($wump, '-I' . dirname($wump) . '/lib', '-Iperl/lib',
					'bench/api-overhead.pl', $op, $mode, $n);
				is($status, 0, "$op/$mode API probe completes $n operations on $slots slots");
				is($errors, '', 'API probe has no diagnostics');
				my $value = eval {decode_json($text)};
				is_deeply($value && [@{$value}{qw(operation mode iterations slots completed)}],
					[$op, $mode, $n, $slots, $n], 'probe retains its identity and verifies the completion count');
			}
		}
	}
}

for my $op (qw(buffered rendezvous)) {
	for my $mode (qw(wrapper xs native)) {
		for my $slots (1,4) {
			for my $n (1,98) {
				local $ENV{WUMPPROCS}=$slots;
				($status,$text,$errors)=run($wump,'-I'.dirname($wump).'/lib','-Iperl/lib',
					'bench/channel-overhead.pl',$op,$mode,$n);
				is($status,0,"$op/$mode channel probe completes $n exchanges on $slots slots");
				is($errors,'','channel probe has no diagnostics');
				my $sample=eval {decode_json($text)};
				ok(ref($sample) eq 'HASH' && $sample->{operation} eq $op && $sample->{mode} eq $mode
					&& $sample->{slots}==$slots && $sample->{iterations}==$n && $sample->{completed}==$n
					&& $sample->{checksum}==$n*($n+1)/2+($op eq 'rendezvous' ? $n : 0)
					&& $sample->{wall_seconds}>0,'channel probe verifies every reply, count and checksum');
			}
		}
	}
}
{
	open my $out,'>',"$scratch/WumpChannelOverride.pm" or die $!;
	print {$out} q{require Wump; no warnings 'redefine'; *Wump::Channel::send=\&Wump::_send; 1;} or die $!;
	close $out or die $!;
	($status,$text,$errors)=run($wump,'-I'.dirname($wump).'/lib','-Iperl/lib',"-I$scratch",'-MWumpChannelOverride',
		'bench/channel-overhead.pl','buffered','native',1);
	ok($status!=0,'a native channel probe rejects a method rebound to ordinary XS');
	like($errors,qr/native channel send entry is unavailable/,'missing native binding is diagnosed before timing');
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
