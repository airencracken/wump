use v5.42;
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Temp qw(tempdir tempfile);
use IPC::Open3;

my $scratch = tempdir(CLEANUP => 1);
open my $original, '<', 'bench/perl-active-after.jsonl' or die $!;
my @original = map { decode_json($_) } <$original>;
close $original or die $!;
sub fixture ($name, $edit = sub {}) {
	my $records = decode_json(encode_json(\@original));
	$edit->($records);
	my $path = "$scratch/$name.jsonl";
	open my $output, '>', $path or die $!;
	print {$output} encode_json($_), "\n" for @$records;
	close $output or die $!;
	return $path;
}
sub run ($before, $after, @options) {
	my ($errors) = tempfile(UNLINK => 1);
	my ($input, $output);
	my @switches = map { "-I$_" } grep { !ref } @INC;
	my $pid = open3($input, $output, '>&' . fileno($errors), $^X,
		@switches, 'bench/perl-baseline-check.pl', $before, $after, @options);
	close $input or die $!;
	my $text = do { local $/; <$output> };
	close $output or die $!;
	waitpid($pid, 0) == $pid or die $!;
	my $status = $?;
	seek $errors, 0, 0 or die $!;
	$text .= do { local $/; <$errors> };
	return ($status >> 8, $text);
}
sub scale ($records, $factor, $variant = undef, $process_only = 0) {
	for my $record (@$records) {
		next if defined($variant) && $record->{variant} ne $variant;
		if ($record->{kind} eq 'sample') {
			$record->{wall_seconds} *= $factor unless $process_only;
			$record->{process_seconds} *= $factor;
		} else { $record->{median_wall_seconds} *= $factor unless $process_only }
	}
}
my $baseline = fixture('before with spaces');
my ($status, $text) = run($baseline, $baseline);
is($status, 0, 'identical complete captures pass');
is(scalar(() = $text =~ /^PASS /mg), 8, 'ordinary and all slot counts check work and process timing');
my $affinity = fixture('recorded affinity', sub { $_->{cpu_affinity} = '0-15' for @{$_[0]} });
($status, $text) = run($affinity, $affinity);
is($status, 0, 'matching recorded CPU affinity passes');
($status, $text) = run($affinity, fixture('pinned affinity', sub {
	$_->{cpu_affinity} = '0,2,4,6,8,10,12,14' for @{$_[0]};
}));
isnt($status, 0, 'different CPU affinity cannot silently pass');
like($text, qr/different CPU affinity/, 'affinity mismatch is identified');
($status, $text) = run($baseline, $affinity);
is($status, 0, 'legacy evidence remains comparable');
like($text, qr/NOTE CPU affinity is unrecorded/, 'legacy affinity assumption is explicit');
for my $mask ('', '0-', '0 1', 'arbitrary', []) {
	($status, $text) = run($affinity, fixture('invalid affinity', sub { $_->{cpu_affinity} = $mask for @{$_[0]} }));
	isnt($status, 0, 'invalid affinity evidence fails');
	like($text, qr/invalid CPU affinity/, 'invalid affinity is identified');
}
($status, $text) = run($affinity, fixture('mixed affinity', sub {
	$_->{cpu_affinity} = '0-15' for @{$_[0]};
	$_[0][0]{cpu_affinity} = '0-7';
}));
isnt($status, 0, 'mixed affinity within a capture fails');
like($text, qr/mixed CPU affinity/, 'mixed affinity is identified');
($status, $text) = run($affinity, fixture('partial affinity', sub {
	$_->{cpu_affinity} = '0-15' for @{$_[0]};
	delete $_[0][0]{cpu_affinity};
}));
isnt($status, 0, 'partly missing affinity evidence fails');
($status, $text) = run($baseline, fixture('slower host', sub { scale($_[0], 1.5) }));
is($status, 0, 'uniform host slowdown cancels against the matched stock control');
for my $variant (qw(fork wump-1 wump-2 wump-4)) {
	($status, $text) = run($baseline, fixture("$variant regression", sub { scale($_[0], 1.11, $variant) }));
	is($status, 1, "$variant 11 percent regression fails");
	like($text, qr/^FAIL \Q$variant\E work:/m, 'work regression names its mode');
}
for my $factor (0.5, 1.09, 1.10) {
	($status, $text) = run($baseline, fixture("factor $factor", sub { scale($_[0], $factor, 'wump-1') }));
	is($status, 0, "factor $factor stays within the default budget, including the exact boundary");
}
my $nine_percent = fixture('nine percent', sub { scale($_[0], 1.09, 'wump-1') });
($status, $text) = run($baseline, $nine_percent, '--max-regression', 5);
is($status, 1, 'a tighter explicit budget is enforced');
($status, $text) = run($baseline, $baseline, '--max-regression', 0);
is($status, 0, 'zero budget accepts an identical capture');
($status, $text) = run($baseline, fixture('process regression', sub { scale($_[0], 1.11, 'wump-2', 1) }));
is($status, 1, 'process overhead regression fails even when work timing is unchanged');
like($text, qr/^PASS wump-2 work:.*^FAIL wump-2 process:/ms, 'process and work checks stay separate');

sub add_eight ($records) {
	my @added = map { +{%$_, variant => 'wump-8', execution_slots => 8} }
		grep { $_->{variant} eq 'wump-4' } @$records;
	push @$records, @added;
}
my $extended = fixture('eight slots', \&add_eight);
($status, $text) = run($extended, $extended);
is($status, 0, 'complete extended captures pass');
is(scalar(() = $text =~ /^PASS /mg), 10, 'extended captures also check eight-slot work and process timing');
($status, $text) = run($baseline, $extended);
isnt($status, 0, 'different execution-mode sets cannot be compared');
($status, $text) = run($extended, fixture('eight-slot regression', sub { add_eight($_[0]); scale($_[0], 1.11, 'wump-8') }));
is($status, 1, 'eight-slot regression fails');
like($text, qr/^FAIL wump-8 work:.*^FAIL wump-8 process:/ms, 'extended regression names both metrics');
($status, $text) = run($extended, fixture('incomplete eight slots', sub {
	add_eight($_[0]); @{$_[0]} = grep { !($_->{variant} eq 'wump-8' && $_->{kind} eq 'sample' && $_->{sample} == 1) } @{$_[0]};
}));
isnt($status, 0, 'partial eight-slot evidence cannot pass');
like($text, qr/incomplete wump-8 samples/, 'missing extended sample is identified');
($status, $text) = run($baseline, fixture('advertised but absent eight slots', sub {
	$_->{max_slots} = 8 for grep { $_->{kind} eq 'summary' } @{$_[0]};
}));
isnt($status, 0, 'advertised eight-slot mode cannot be omitted entirely');
like($text, qr/missing wump-8 summary/, 'missing advertised mode is identified');
($status, $text) = run($extended, fixture('contradictory eight slots', sub {
	add_eight($_[0]); $_->{max_slots} = 4 for grep { $_->{kind} eq 'summary' } @{$_[0]};
}));
isnt($status, 0, 'extended samples cannot contradict their declared mode set');
like($text, qr/mismatched execution-mode declaration/, 'contradictory mode declaration is identified');

for my $case (
	['dirty source', sub { $_->{source_dirty} = JSON::PP::true for @{$_[0]} }, qr/dirty or missing source state/],
	['unknown mode', sub { $_[0][0]{variant} = 'wump-3' }, qr/unknown execution variant/],
	['missing source state', sub { delete $_[0][0]{source_dirty} }, qr/dirty or missing source state/],
	['unverified result', sub { $_[0][0]{verified_jobs}-- }, qr/unverified jobs/],
	['missing mode', sub { @{$_[0]} = grep { $_->{variant} ne 'wump-4' } @{$_[0]} }, qr/missing wump-4 summary/],
	['missing sample', sub { shift @{$_[0]} }, qr/incomplete .* samples/],
	['duplicate sample', sub { push @{$_[0]}, $_[0][0] }, qr/duplicate sample/],
	['duplicate summary', sub { push @{$_[0]}, $_[0][-1] }, qr/duplicate summary/],
	['forged median', sub { $_[0][-1]{median_wall_seconds} *= 0.5 }, qr/inconsistent median/],
	['nonfinite timing', sub { $_[0][0]{wall_seconds} = 'NaN' }, qr/invalid timing/],
	['impossible timing', sub { $_[0][0]{process_seconds} = 0.00001 }, qr/invalid timing/],
	['wrong slot count', sub { $_[0][0]{execution_slots} = 4 }, qr/invalid execution slots/],
	['mixed source', sub { $_[0][0]{source_revision} = 'a' x 40 }, qr/mixed configurations or revisions/],
	['other CPU', sub { $_->{cpu_model} = 'another CPU' for @{$_[0]} }, qr/different workloads, machines or build configurations/],
	['other workload', sub { $_->{iterations}++ for @{$_[0]} }, qr/different workloads, machines or build configurations/],
	['instrumented capture', sub { $_->{fork_config}{ccflags} .= ' -fsanitize=thread' for @{$_[0]} }, qr/instrumented build/],
	['mismatched stock', sub { $_->{stock_config}{optimize} = '-O0' for @{$_[0]} }, qr/stock\/fork build mismatch/],
	['too few runs', sub { $_->{runs} = 2 for grep { $_->{kind} eq 'summary' } @{$_[0]} }, qr/at least three runs/],
) {
	my ($name, $edit, $expected) = @$case;
	($status, $text) = run($baseline, fixture($name, $edit));
	isnt($status, 0, "$name cannot produce a passing comparison");
	like($text, $expected, 'failure identifies the invalid evidence');
}
for my $limit ('-1', 'NaN', '101', 'garbage') {
	($status, $text) = run($baseline, $baseline, '--max-regression', $limit);
	isnt($status, 0, "invalid regression limit $limit is rejected");
}
my $bad = "$scratch/broken.jsonl";
open my $output, '>', $bad or die $!;
print {$output} "{invalid\n" or die $!;
close $output or die $!;
($status, $text) = run($baseline, $bad);
isnt($status, 0, 'malformed JSON fails');
like($text, qr/invalid JSON record/, 'malformed JSON has a useful diagnostic');
done_testing;
