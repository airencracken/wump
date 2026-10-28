package WumpDemo::App;
use v5.42;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::JSON 'true';
use Scalar::Util 'weaken';
use WumpDemo::Jobs;

has jobs => sub { WumpDemo::Jobs->new };
has event_interval => 0.1;
has subscribers => 0;

sub startup ($self) {
	$self->log->level('warn');
	$self->exception_format('json');
	# All paths are explicit so running from a different directory works too.
	$self->static->paths([__FILE__ =~ s{lib/WumpDemo/App\.pm\z}{public}r]);
	$self->max_request_size(512 * 1024);
	my $routes = $self->routes;
	weaken $self;
	$routes->get('/')->to(cb => sub ($c) { $c->reply->static('index.html') });
	$routes->get('/health')->to(cb => sub ($c) {
		$c->render(json => {ok => true, pid => 0 + $$, runtime => 'single-slot'});
	});
	$routes->get('/jobs')->to(cb => sub ($c) { $c->render(json => $self->jobs->snapshot) });
	$routes->post('/jobs')->to(cb => sub ($c) {
		my $body = $c->req->json;
		return $c->render(status => 400, json => {error => 'Expected a JSON object'}) unless ref($body) eq 'HASH';
		my ($id, $status, $error) = $self->jobs->submit($body->{text}, exists($body->{passes}) ? $body->{passes} : 1);
		if ($error) {
			$c->res->headers->header('Retry-After' => 1) if $status == 429;
			return $c->render(status => $status, json => {error => $error});
		}
		$c->res->headers->location("/jobs/$id");
		$c->render(status => 202, json => $self->jobs->get($id));
	});
	$routes->get('/jobs/:id')->to(cb => sub ($c) {
		my $job = $self->jobs->get($c->stash('id'));
		$c->render(status => $job ? 200 : 404, json => $job // {error => 'Unknown job'});
	});
	$routes->delete('/jobs/:id')->to(cb => sub ($c) {
		my $job = $self->jobs->cancel($c->stash('id'));
		$c->render(status => $job ? 202 : 404, json => $job // {error => 'Unknown job'});
	});
	$routes->websocket('/events')->to(cb => sub ($c) {
		$c->inactivity_timeout(30);
		$self->subscribers($self->subscribers + 1);
		my ($pending, $last_version, $ticks) = (0, -1, 0);
		my $weak = $c;
		weaken $weak;
		my $timer = Mojo::IOLoop->recurring($self->event_interval => sub {
			# A timer can fire while the upgrade response is still draining.
			# Controller::send would resume that HTTP handshake a second time.
			return unless $weak && $weak->tx && $weak->tx->established && !$pending;
			my $snapshot = $self->jobs->snapshot;
			return if $snapshot->{version} == $last_version && ++$ticks < 10;
			$ticks = 0;
			$last_version = $snapshot->{version};
			$pending = 1;
			# At most one frame is queued per subscriber, even for slow clients.
			$weak->send({json => $snapshot} => sub { $pending = 0 });
		});
		$c->on(finish => sub {
			Mojo::IOLoop->remove($timer);
			$self->subscribers($self->subscribers - 1);
		});
	});
}

1;
