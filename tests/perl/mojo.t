use v5.42;
use strict;
use warnings;
BEGIN {
	$ENV{MOJO_REACTOR} = 'Wump::Mojo::Reactor';
	$ENV{MOJO_NO_JSON_XS} = $ENV{MOJO_NO_TLS} = $ENV{MOJO_NO_NNR} = $ENV{MOJO_NO_SOCKS} = 1;
}
use Test::More;
use Test::Mojo;
use Time::HiRes 'time';
use Wump;
use Wump::Mojo::Reactor;
use WumpDemo::App;
use WumpDemo::Analysis qw(reference summary);
alarm 60;

my $reactor = Wump::Mojo::Reactor->new;
$reactor->start;
ok(!$reactor->is_running, 'empty reactor stops');
my ($computed, $timer) = (0, 0);
my $end = time + 0.15;
my $wg = waitgroup;
add $wg;
act { $computed++ while time < $end; done $wg };
$reactor->timer(0.03 => sub { $timer = 1; $reactor->stop });
$reactor->start;
ok($timer && $computed, 'reactor timer and CPU act progress without worker yields');
await $wg;
is(scalar keys %{$reactor->{timers}}, 0, 'bridge leaves no wakeup timers');

my $jobs = WumpDemo::Jobs->new(workers => 2, max_active => 2, max_history => 3, chunk_lines => 1);
# An immediately due publisher also exercises ticks before upgrade completes.
my $app = WumpDemo::App->new(jobs => $jobs, event_interval => 0);
my $t = Test::Mojo->new($app);
$t->ua->request_timeout(3);
$t->get_ok('/')->status_is(200)->content_like(qr/Keep the work moving/);
$t->get_ok('/dashboard.js')->status_is(200)->content_like(qr/textContent/);
$t->get_ok('/dashboard.css')->status_is(200);
$t->get_ok('/health')->status_is(200)->json_is('/runtime', 'single-slot')->json_is('/pid', 0 + $$);
$t->json_is('/execution_slots', 1);
$t->get_ok('/jobs/missing')->status_is(404);
$t->delete_ok('/jobs/missing')->status_is(404);
for my $body ([], undef, 'string') {
	$t->post_ok('/jobs' => json => $body)->status_is(400);
}
$t->post_ok('/jobs' => {'Content-Type' => 'application/json'} => '{bad')->status_is(400);
$t->post_ok('/jobs' => json => {text => []})->status_is(400);
$t->post_ok('/jobs' => json => {text => 'x', passes => -1})->status_is(400);
$t->post_ok('/jobs' => json => {text => 'x', passes => undef})->status_is(400);
$t->post_ok('/jobs' => json => {text => 'x' x 65537})->status_is(413);

$t->websocket_ok('/events');
my $connected = time;
my @closed;
$t->tx->on(finish => sub ($tx, @reason) { @closed = @reason });
is($app->subscribers, 1, 'WebSocket registered at handshake');
$t->message_ok;
diag('WebSocket closed after ' . (time - $connected) . ' seconds: ' . join(', ', @closed)) if @closed;
is($app->subscribers, 1, 'WebSocket registered');
my $event = Mojo::JSON::decode_json($t->message->[1]);
is($event->{runtime}, 'single-slot', 'WebSocket sends service snapshot');
is($event->{execution_slots}, 1, 'WebSocket reports the actual execution slots');
$t->finish_ok;
$t->get_ok('/health')->status_is(200);
is($app->subscribers, 0, 'WebSocket disconnect removes subscriber timer');

my $text = "INFO caf\x{e9} hello\nWARN hello\n";
$t->post_ok('/jobs' => json => {text => $text, passes => 4})->status_is(202)->header_like(Location => qr{\A/jobs/\d+\z});
my $id = $t->tx->res->json->{id};
my $deadline = time + 10;
sleep 0.001 until $jobs->get($id)->{terminal} || time > $deadline;
$t->get_ok("/jobs/$id")->status_is(200)->json_is('/state', 'completed')->json_is('/result', summary(reference($text, 4)));
$t->get_ok('/jobs')->status_is(200)->json_is('/metrics/active', 0);

# Direct admission fills the service before the next HTTP event-loop tick.
my ($a) = $jobs->submit('a');
my ($b) = $jobs->submit('b');
is(($jobs->submit('c'))[1], 429, 'admission bound applies while HTTP event loop is idle');
$jobs->cancel($a);
$t->delete_ok("/jobs/$b")->status_is(202);
$jobs->shutdown;
$t->post_ok('/jobs' => json => {text => 'after shutdown'})->status_is(503);
my $release = 0;
my $gated = WumpDemo::Jobs->new(max_active => 1, analyzer => sub (@args) {
	sleep 0.001 until $release;
	return WumpDemo::Analysis::analyze_chunk(@args);
});
my $busy_app = WumpDemo::App->new(jobs => $gated);
my $busy = Test::Mojo->new($busy_app);
$busy->post_ok('/jobs' => json => {text => 'held'})->status_is(202);
$busy->post_ok('/jobs' => json => {text => 'overflow'})->status_is(429)->header_is('Retry-After' => 1);
$release = 1;
$gated->shutdown;
Mojo::IOLoop->reset;
done_testing;
