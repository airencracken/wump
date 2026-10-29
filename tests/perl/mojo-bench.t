use v5.42;
use strict;
use warnings;
use Test::More;
use JSON::PP 'decode_json';
use Cwd 'abs_path';

my $private = abs_path(shift // die "Usage: perl $0 PRIVATE_PERL\n");
open my $child, '-|', $^X, 'bench/mojo-cpu.pl', $private,
	'--runs', 2, '--jobs', 2, '--passes', 1, '--workers', 4 or die "Start benchmark test: $!\n";
my @records;
while (my $line = <$child>) {
	push @records, decode_json($line);
}
close $child;
is($?, 0, 'benchmark compares verified job batches on one, two and four slots');
my @samples = grep { $_->{kind} eq 'sample' } @records;
my @summaries = grep { $_->{kind} eq 'summary' } @records;
is(scalar @samples, 6, 'two raw samples retained for every slot count');
is_deeply([map { $_->{execution_slots} } @summaries], [1, 2, 4], 'summaries identify actual execution slots');
for my $sample (@samples) {
	is($sample->{verified_jobs}, 2, 'every timed job checked against the sequential reference');
	is($sample->{workers}, 4, 'worker count stays fixed across slot counts');
	is($sample->{passes}, 1, 'analysis work stays fixed across slot counts');
	cmp_ok($sample->{wall_seconds}, '>', 0, 'sample measures a positive job interval');
	cmp_ok($sample->{process_seconds}, '>=', $sample->{wall_seconds}, 'process timing includes setup outside job timing');
	like($sample->{source_revision}, qr/\A[0-9a-f]{40,64}\z/, 'sample records its source revision');
	like($sample->{perl_version}, qr/\Av5\.42\./, 'sample records the executable Perl version');
}
for my $summary (@summaries) {
	cmp_ok($summary->{speedup}, '>', 0, 'speedup is measured without imposing a scaling threshold');
	my @wall = sort {$a <=> $b} map { $_->{wall_seconds} }
		grep { $_->{execution_slots} == $summary->{execution_slots} } @samples;
	is($summary->{median_wall_seconds}, ($wall[0] + $wall[1]) / 2, 'even sample count uses the mean of the middle observations');
}

open my $invalid, '-|', $^X, 'bench/mojo-cpu.pl', $private, '--runs', 0
	or die "Start invalid benchmark: $!\n";
my $invalid_output = do { local $/; <$invalid> };
close $invalid;
isnt($?, 0, 'invalid repetition count fails before starting benchmark samples');
is($invalid_output, '', 'invalid configuration emits no measurements');
done_testing;
