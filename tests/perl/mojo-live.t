use v5.42;
use strict;
use warnings;
BEGIN {
	delete $ENV{MOJO_REACTOR};
	$ENV{MOJO_NO_JSON_XS} = $ENV{MOJO_NO_TLS} = $ENV{MOJO_NO_NNR} = $ENV{MOJO_NO_SOCKS} = 1;
}
use Test::More;
use FindBin;
use Cwd 'abs_path';
use IPC::Open3;
use IO::Select;
use File::Temp 'tempfile';
use POSIX 'WNOHANG';
use Time::HiRes qw(time sleep);
use Mojo::UserAgent;
use Mojo::Promise;
use Mojo::JSON qw(decode_json encode_json);
use lib "$FindBin::Bin/../../examples/mojo/lib";
use WumpDemo::Analysis qw(reference summary);

my $private = abs_path(shift // die "Usage: perl $0 PRIVATE_PERL [HEALTH_P95_MS]\n");
my $budget = shift // 1000;
die "Invalid latency budget\n" unless $budget =~ /\A[1-9][0-9]*\z/;
my $root = abs_path("$FindBin::Bin/../..");
my ($pid, $output, $errors, $error_path);
my $ua = Mojo::UserAgent->new->ioloop(Mojo::IOLoop->singleton)
	->request_timeout(10)->connect_timeout(3)->max_connections(16);
alarm 120;
END {
	if ($pid) {
		kill 'TERM', $pid;
		my $until = time + 2;
		while (time < $until) { last if waitpid($pid, WNOHANG) == $pid; sleep 0.01 }
		if (kill 0, $pid) { kill 'KILL', $pid; waitpid($pid, 0) }
	}
}
sub server_event () {
	my $ready = IO::Select->new($output)->can_read(15);
	die "Server output timed out\n" unless $ready;
	my $line = <$output>;
	unless (defined $line) {
		seek $errors, 0, 0;
		my $log = do { local $/; <$errors> };
		die "Server exited before its next event:\n$log";
	}
	return decode_json($line);
}
sub start_server ($port = 0) {
	($errors, $error_path) = tempfile('wump-mojo-live-XXXXXX', TMPDIR => 1, UNLINK => 1);
	my $input;
	# PRIVATE_PERL is the executable in a configured source tree.
	(my $directory = $private) =~ s{/perl\z}{};
	$pid = open3($input, $output, '>&' . fileno($errors), $private, "-I$directory/lib",
		"$root/examples/mojo/dashboard.pl", '--listen', "http://127.0.0.1:$port",
		'--max-active', 2, '--max-history', 3);
	close $input;
	my $event = server_event();
	is($event->{event}, 'ready', 'server bound a real TCP listener');
	is($event->{pid}, $pid, 'server reports one process');
	is($event->{runtime}, 'single-slot', 'server reports actual execution mode');
	is($event->{execution_slots}, 1, 'server reports actual execution slots independently of coroutine workers');
	return "http://127.0.0.1:$event->{port}";
}
sub stop_server () {
	ok(kill('TERM', $pid), 'SIGTERM delivered');
	my $event = server_event();
	is($event->{event}, 'stopped', 'server completed shutdown protocol');
	is($event->{active}, 0, 'shutdown joined actors and drained active jobs');
	my $deadline = time + 10;
	my $reaped;
	while (time < $deadline) {
		$reaped = waitpid($pid, WNOHANG);
		last if $reaped == $pid;
		sleep 0.01;
	}
	die "Server did not exit after shutdown\n" unless $reaped == $pid;
	is($?, 0, 'server exited successfully');
	$pid = undef;
	close $output;
	seek $errors, 0, 0;
	my $log = do { local $/; <$errors> };
	is($log, '', 'server emitted no warnings or errors');
	close $errors;
	return $event;
}
sub json_get ($url) {
	my $tx = $ua->get($url);
	die "GET $url failed: " . ($tx->error->{message} // 'unknown') . "\n" unless $tx->res->is_success;
	return $tx->res->json;
}
sub rss_kib () {
	open my $status, '<', "/proc/$pid/status" or die "Read server RSS: $!\n";
	while (<$status>) { return 0 + $1 if /\AVmRSS:\s+(\d+)/ }
	die "Server RSS unavailable\n";
}
my $base = start_server();
my ($port) = $base =~ /:(\d+)\z/;
my ($socket, $frames, $active_frames) = (undef, 0, 0);
$ua->websocket("$base/events" => sub ($agent, $tx) {
	die "WebSocket handshake failed\n" unless $tx->is_websocket;
	$socket = $tx;
	$tx->on(json => sub ($tx, $event) { $frames++; $active_frames++ if $event->{metrics}{active} });
	Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;
ok($socket, 'real WebSocket connected');
my $text = "INFO Caf\x{e9} request cache hit\nWARN request cache miss\n" x 300;
my $expected = summary(reference($text, 100));
my (@submitted, @codes);
Mojo::Promise->all(map {
	$ua->post_p("$base/jobs" => json => {text => $text, passes => 100})->then(sub ($tx) {
		push @codes, $tx->res->code;
		push @submitted, $tx->res->json->{id} if $tx->res->code == 202;
		is($tx->res->headers->header('Retry-After'), 1, 'saturated HTTP response asks client to retry') if $tx->res->code == 429;
	})
} 1..3)->wait;
is_deeply([sort {$a <=> $b} @codes], [202, 202, 429], 'concurrent submissions enforce bounded admission over TCP');
my (@latencies, $responsive_while_active);
my $deadline = time + 40;
while (1) {
	my $snapshot = json_get("$base/jobs");
	last unless $snapshot->{metrics}{active};
	die "Jobs did not complete\n" if time > $deadline;
	my $start = time;
	my $health = json_get("$base/health");
	push @latencies, 1000 * (time - $start);
	is($health->{pid}, $pid, 'health served by worker process') unless $responsive_while_active;
	$responsive_while_active++;
	# Network waits drive the client event loop, including progress frames.
	$ua->get("$base/health");
}
ok($responsive_while_active, 'health replies arrive while CPU jobs are active');
ok($active_frames, 'WebSocket reports progress while CPU jobs are active');
for my $id (@submitted) {
	my $job = json_get("$base/jobs/$id");
	is($job->{state}, 'completed', "TCP job $id completed");
	is_deeply($job->{result}, $expected, "TCP job $id equals stock-Perl sequential reference");
}
my @ordered = sort {$a <=> $b} @latencies;
my $p95 = $ordered[int(0.95 * @ordered + 0.999999) - 1] // 0;
cmp_ok($p95, '<', $budget, "health p95 stays below ${budget}ms under CPU load");
diag(encode_json({execution_slots => 1, health_samples => scalar @latencies,
	health_p95_ms => 0 + sprintf('%.2f', $p95), websocket_frames => $frames}));

$socket->finish;
$ua->get("$base/health");
$socket = undef;
my $warm_rss = rss_kib();
for my $batch (1..12) {
	my $tx = $ua->post("$base/jobs" => json => {text => "INFO repeat $batch", passes => 2});
	is($tx->res->code, 202, "repeat request $batch admitted");
	my $id = $tx->res->json->{id};
	my $until = time + 5;
	while (!json_get("$base/jobs/$id")->{terminal}) { die "Repeat job timed out\n" if time > $until }
}
my $snapshot = json_get("$base/jobs");
is(scalar @{$snapshot->{jobs}}, 3, 'HTTP history stays within retention limit');
cmp_ok(rss_kib() - $warm_rss, '<', 16 * 1024, 'repeated batches stay within a 16MiB RSS growth budget');
my $cancel_tx = $ua->post("$base/jobs" => json => {text => $text, passes => 100});
is($cancel_tx->res->code, 202, 'cancellable job admitted');
my $cancel_id = $cancel_tx->res->json->{id};
is($ua->delete("$base/jobs/$cancel_id")->res->code, 202, 'HTTP cancellation accepted');
my $until = time + 5;
while (!json_get("$base/jobs/$cancel_id")->{terminal}) { die "Cancellation timed out\n" if time > $until }
is(json_get("$base/jobs/$cancel_id")->{state}, 'cancelled', 'HTTP cancellation reaches terminal state');

$ua->post("$base/jobs" => json => {text => $text, passes => 100});
my $stopped = stop_server();
cmp_ok($stopped->{cancelled}, '>=', 2, 'SIGTERM cancels in-flight CPU work');
$ua = Mojo::UserAgent->new->request_timeout(5);
$base = start_server($port);
ok(json_get("$base/health")->{ok}, 'same port can be rebound after shutdown');
stop_server();
done_testing;
