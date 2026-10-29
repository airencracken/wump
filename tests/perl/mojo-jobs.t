use v5.42;
use strict;
use warnings;
use Test::More;
use Time::HiRes 'time';
use Wump;
use WumpDemo::Jobs;
use WumpDemo::Analysis qw(lines analyze_chunk reference summary);

alarm 60;
sub wait_for ($service, $id) {
	my $deadline = time + 10;
	while (!$service->get($id)->{terminal}) {
		die "Timed out waiting for job $id\n" if time > $deadline;
		sleep 0.001;
	}
	return $service->get($id);
}
my $unicode = "INFO Caf\x{e9} cafe\x{301} Stra\x{df}e STRASSE\r\nWARN can't can\x{2019}t\0\n\n";
my $expected = {lines => 3, words => 8, counts => {
	info => 1, "caf\x{e9}" => 2, strasse => 2, warn => 1, "can't" => 1, "can\x{2019}t" => 1,
}, levels => {INFO => 1, WARN => 1, OTHER => 1}};
is_deeply(reference($unicode), $expected, 'reference matches a hand-counted Unicode/CRLF/NUL fixture');
is_deeply(analyze_chunk(lines($unicode), 1, sub { 0 }), $expected, 'worker matches hand-counted fixture');
is_deeply(lines(''), [], 'empty input has no lines');
is_deeply(lines("\n\n"), ['', ''], 'blank lines are retained without a phantom trailing line');
is_deeply(analyze_chunk(['anything'], 5, sub { 1 }), {cancelled => 1}, 'cancelled analysis stops before scanning');

my $service = WumpDemo::Jobs->new(workers => 3, chunk_lines => 1, max_active => 2, max_history => 3);
is($service->snapshot->{execution_slots}, 1, 'service reports execution slots independently of its worker count');
my ($first, $status) = $service->submit($unicode, 3);
is($status, 202, 'first job admitted');
my ($second) = $service->submit("INFO next\n", 2);
my (undef, $full) = $service->submit('overflow');
is($full, 429, 'running and queued jobs share the admission bound');
is_deeply(wait_for($service, $first)->{result}, summary(reference($unicode, 3)), 'chunked multiworker result equals sequential reference');
is(wait_for($service, $second)->{state}, 'completed', 'queued job completes');
is($service->snapshot->{metrics}{active}, 0, 'collector releases admission exactly once per job');
is($service->snapshot->{metrics}{rejected}, 1, 'rejection counted');
for my $index (1..5) {
	my ($id) = $service->submit("INFO repeated $index");
	is(wait_for($service, $id)->{state}, 'completed', "repeat batch $index completes");
}
is(scalar @{$service->snapshot->{jobs}}, 3, 'retained history stays bounded');
is($service->get($first), undef, 'old terminal job evicted');
is($service->cancel('missing'), undef, 'unknown cancellation returns no job');
my $copy = $service->snapshot;
$copy->{jobs}[0]{state} = 'corrupt';
isnt($service->snapshot->{jobs}[0]{state}, 'corrupt', 'snapshots do not expose mutable catalog state');
$service->shutdown;
$service->shutdown;
is(($service->submit('after shutdown'))[1], 503, 'stopped service rejects submissions');
ok(!grep(defined $_->{job}, @{$service->snapshot->{workers}}), 'shutdown leaves workers idle');

my $unused = WumpDemo::Jobs->new;
$unused->shutdown;
is(($unused->submit('after unused shutdown'))[1], 503, 'shutdown before lazy start cannot restart actors');

my $failed = WumpDemo::Jobs->new(workers => 2, chunk_lines => 1, max_unique => 2);
my ($bad) = $failed->submit("one two\nthree four");
my $bad_job = wait_for($failed, $bad);
is($bad_job->{state}, 'failed', 'collector enforces distinct-word bound across chunks');
like($bad_job->{error}, qr/Too many distinct words/, 'worker failure is reported');
my ($good) = $failed->submit('one one');
is(wait_for($failed, $good)->{state}, 'completed', 'pool recovers after failed job');
$failed->shutdown;

my $throws = WumpDemo::Jobs->new(workers => 1, analyzer => sub ($lines, @rest) {
	die "injected analyzer failure\n" if $lines->[0] eq 'boom';
	return analyze_chunk($lines, @rest);
});
my ($throw_id) = $throws->submit('boom');
like(wait_for($throws, $throw_id)->{error}, qr/injected analyzer failure/, 'unexpected worker exception becomes a failed job');
my ($recover_id) = $throws->submit('healthy');
is(wait_for($throws, $recover_id)->{state}, 'completed', 'same worker accepts work after an exception');
$throws->shutdown;

my $cancel = WumpDemo::Jobs->new(workers => 2, chunk_lines => 1, analyzer => sub ($lines, $passes, $cancelled, $max) {
	sleep 0.002 until $cancelled->();
	return {cancelled => 1};
});
my ($running) = $cancel->submit("INFO running\n" x 40);
my ($queued) = $cancel->submit('queued');
my $deadline = time + 5;
sleep 0.001 until $cancel->get($running)->{state} eq 'running' || time > $deadline;
is($cancel->get($running)->{state}, 'running', 'cancellation test reached an executing worker');
$cancel->cancel($queued);
$cancel->cancel($running);
is(wait_for($cancel, $running)->{state}, 'cancelled', 'running job cancels cooperatively');
is(wait_for($cancel, $queued)->{state}, 'cancelled', 'queued job cancels without losing completion accounting');
my ($stopping) = $cancel->submit("INFO stopping\n" x 40);
sleep 0.005;
$cancel->shutdown;
is($cancel->get($stopping)->{state}, 'cancelled', 'shutdown cancels pending work and joins actors');
is($cancel->snapshot->{metrics}{active}, 0, 'shutdown drains bounded result queues without deadlock');

my $validation = WumpDemo::Jobs->new(max_bytes => 4, max_passes => 2);
for my $case ([undef, 1, 400], [[], 1, 400], ['', 1, 400], ['12345', 1, 413],
	["\x{100}" x 3, 1, 413], ['ok', 0, 400], ['ok', {}, 400], ['ok', 3, 400]) {
	is(($validation->submit($case->[0], $case->[1]))[1], $case->[2], 'invalid input rejected before admission');
}
$validation->shutdown;
done_testing;
