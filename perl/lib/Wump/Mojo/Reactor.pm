package Wump::Mojo::Reactor;
use v5.42;
use Mojo::Base 'Mojo::Reactor::Poll', -signatures;
use Wump ();

has poll_interval => 0.002;

sub one_tick ($self) {
	# Preserve Poll's empty-loop stop behavior. A zero-time timer otherwise
	# bounds the native poll to zero, even if the next real timer is far away.
	return $self->SUPER::one_tick
		unless keys %{$self->{io} // {}} || keys %{$self->{timers} // {}};
	my $wake = $self->timer(0 => sub {});
	my $ok = eval { $self->SUPER::one_tick; 1 };
	my $error = $@;
	$self->remove($wake);
	die $error unless $ok;
	Wump::sleep($self->poll_interval);
	return;
}

1;
