package Wump::Mojo::Daemon;
use v5.42;
use Mojo::Base 'Mojo::Server::Daemon', -signatures;

sub prepare ($self) {
	my $phase = ${^GLOBAL_PHASE};
	die "Wump: prepare listeners before program execution\n"
		unless $phase eq 'START' || $phase eq 'CHECK' || $phase eq 'INIT';
	# Helper namespaces are generated lazily by Mojo. Build the complete
	# proxy before execution freezes the compiler and shared namespaces.
	$self->app->renderer->get_helper('');
	# Populate Encode's alias cache while its regex-based resolver can run.
	Mojo::Util::decode('UTF-8', Mojo::Util::encode('UTF-8', ''));
	my @routes = ($self->app->routes);
	while (my $route = shift @routes) {
		# Match uses this same endpoint/partial rule for format detection.
		$route->pattern->match('', $route->is_endpoint && !$route->partial);
		push @routes, @{$route->children};
	}
	$self->start;
	for my $id (@{$self->acceptors}) {
		my $listener = $self->ioloop->acceptor($id);
		my $reuse = delete $listener->{reuse};
		next unless defined $reuse && length $reuse;
		# Mojo exports descriptors for forked servers. This daemon owns its
		# listeners in one process; retire only its own export before actors
		# start. DESTROY then needs no process ENV write or runtime regex.
		my (@entries, $removed);
		for my $entry (split /,/, $ENV{MOJO_REUSE} // '', -1) {
			if (!$removed && $entry eq $reuse) { $removed = 1; next }
			push @entries, $entry;
		}
		$ENV{MOJO_REUSE} = join ',', @entries;
	}
	return $self;
}

1;
