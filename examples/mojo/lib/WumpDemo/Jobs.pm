package WumpDemo::Jobs;
use v5.42;
use strict;
use warnings;
use Wump;
use Time::HiRes 'clock_gettime', 'CLOCK_MONOTONIC';
use WumpDemo::Analysis qw(lines analyze_chunk summary);

sub _now () { clock_gettime(CLOCK_MONOTONIC) }
sub _cancelled ($token) { lock $token; return $token->{cancelled} }

sub new ($class, %options) {
	my $self = bless {
		workers => 4, chunk_lines => 32, max_active => 8, max_history => 16,
		max_bytes => 65536, max_passes => 100, max_unique => 4096,
		analyzer => \&analyze_chunk, %options,
	}, $class;
	for my $key (qw(workers chunk_lines max_active max_history max_bytes max_passes max_unique)) {
		die "Invalid $key\n" unless $self->{$key} =~ /\A[1-9][0-9]*\z/;
	}
	die "History must accommodate active jobs\n" if $self->{max_history} < $self->{max_active};
	$self->{state} = {jobs => {}, order => [], active => 0, sequence => 0, version => 0,
		accepted => 0, rejected => 0, completed => 0, failed => 0, cancelled => 0,
		closing => 0, workers => {map { $_ => undef } 1..$self->{workers}}};
	return $self;
}

sub start ($self) {
	return $self if $self->{started};
	die "The service is stopping\n" if $self->{state}{closing};
	$self->{started} = 1;
	my $input = $self->{input} = chan($self->{max_active});
	my $work = chan(2 * $self->{workers});
	my $results = $self->{results} = chan(2 * $self->{workers});
	my $producers = $self->{producers} = waitgroup;
	my $collector = $self->{collector} = waitgroup;
	my ($chunk_lines, $analyzer, $max_unique, $state) = @{$self}{qw(chunk_lines analyzer max_unique state)};
	add $producers;
	act { _dispatch($input, $work, $results, $chunk_lines); done $producers };
	for my $worker (1..$self->{workers}) {
		add $producers;
		act { _worker($worker, $work, $results, $analyzer, $max_unique); done $producers };
	}
	add $collector;
	act { _collect($state, $results, $max_unique); done $collector };
	return $self;
}

sub submit ($self, $text, $passes = 1) {
	return (undef, 400, 'Text must be a nonempty string') if !defined($text) || ref($text) || !length($text);
	my $bytes = do { use bytes; length($text) };
	return (undef, 413, 'Text is too large') if $bytes > $self->{max_bytes};
	return (undef, 400, 'Analysis passes are outside the allowed range')
		if !defined($passes) || ref($passes) || $passes !~ /\A[1-9][0-9]*\z/ || $passes > $self->{max_passes};
	return (undef, 503, 'The service is stopping') if $self->{state}{closing};
	$self->start;
	my ($id, $token);
	my $state = $self->{state};
	{
		lock $state;
		return (undef, 503, 'The service is stopping') if $state->{closing};
		if ($state->{active} >= $self->{max_active}) {
			$state->{rejected}++;
			$state->{version}++;
			return (undef, 429, 'The job queue is full');
		}
		while (@{$state->{order}} >= $self->{max_history}) {
			my ($old) = grep { $state->{jobs}{$_}{terminal} } @{$state->{order}};
			die "No evictable history entry\n" unless defined $old;
			delete $state->{jobs}{$old};
			@{$state->{order}} = grep { $_ ne $old } @{$state->{order}};
		}
		$id = '' . ++$state->{sequence};
		$token = {cancelled => 0};
		$state->{jobs}{$id} = {id => $id, state => 'queued', token => $token,
			passes => 0 + $passes, bytes => $bytes, created => _now(),
			chunks_done => 0, chunks_total => 0, dispatched => 0, terminal => 0,
			result => {lines => 0, words => 0, counts => {}, levels => {}}};
		push @{$state->{order}}, $id;
		$state->{active}++;
		$state->{accepted}++;
		$state->{version}++;
	}
	# Admission counts running jobs too, so this channel always has room.
	# Only the dispatcher parks when its bounded chunk queue fills.
	$self->{input}->send({id => $id, text => $text, passes => 0 + $passes, token => $token});
	return ($id, 202, undef);
}

sub _dispatch ($input, $work, $results, $chunk_lines) {
	while (my $job = $input->recv) {
		my $lines = lines($job->{text});
		my $total = int((@$lines + $chunk_lines - 1) / $chunk_lines);
		$results->send({kind => 'planned', id => $job->{id}, total => $total});
		my $scheduled = 0;
		while (@$lines && !_cancelled($job->{token})) {
			my $chunk = [splice @$lines, 0, $chunk_lines];
			$work->send({id => $job->{id}, lines => $chunk, passes => $job->{passes}, token => $job->{token}});
			$scheduled++;
		}
		$results->send({kind => 'dispatched', id => $job->{id}, scheduled => $scheduled});
	}
	$work->close;
}

sub _worker ($worker, $work, $results, $analyzer, $max_unique) {
	while (my $chunk = $work->recv) {
		$results->send({kind => 'started', id => $chunk->{id}, worker => $worker});
		my ($result, $error);
		eval {
			$result = $analyzer->($chunk->{lines}, $chunk->{passes}, sub { _cancelled($chunk->{token}) }, $max_unique);
			1;
		} or $error = "$@";
		$results->send({kind => 'finished', id => $chunk->{id}, worker => $worker,
			result => $result, error => $error});
	}
}

sub _collect ($state, $results, $max_unique) {
	while (my $event = $results->recv) {
		lock $state;
		my $job = $state->{jobs}{$event->{id}} // die "Missing live job\n";
		if ($event->{kind} eq 'planned') { $job->{chunks_total} = $event->{total} }
		elsif ($event->{kind} eq 'dispatched') {
			$job->{dispatched} = 1;
			$job->{scheduled} = $event->{scheduled};
		} elsif ($event->{kind} eq 'started') {
			$state->{workers}{$event->{worker}} = $job->{id};
			$job->{state} = 'running' unless $job->{terminal};
		} elsif ($event->{kind} eq 'finished') {
			$state->{workers}{$event->{worker}} = undef;
			$job->{chunks_done}++;
			my $part = $event->{result};
			if (defined $event->{error}) { $job->{error} //= substr($event->{error}, 0, 512) }
			elsif ($part && !$part->{cancelled} && !$job->{error}) {
				$job->{result}{lines} += $part->{lines};
				$job->{result}{words} += $part->{words};
				$job->{result}{counts}{$_} += $part->{counts}{$_} for keys %{$part->{counts}};
				$job->{result}{levels}{$_} += $part->{levels}{$_} for keys %{$part->{levels}};
				$job->{error} = "Too many distinct words\n" if keys(%{$job->{result}{counts}}) > $max_unique;
			}
			if ($job->{error}) { lock $job->{token}; $job->{token}{cancelled} = 1 }
		} else { die "Unknown result event\n" }
		if (!$job->{terminal} && $job->{dispatched} && $job->{chunks_done} == $job->{scheduled}) {
			$job->{state} = $job->{error} ? 'failed' : _cancelled($job->{token}) ? 'cancelled' : 'completed';
			$job->{terminal} = 1;
			$job->{finished} = _now();
			$state->{active}--;
			$state->{$job->{state}}++;
		}
		$state->{version}++;
	}
}

sub _snapshot ($job) {
	return {(map { $_ => $job->{$_} } qw(id state passes bytes chunks_done chunks_total terminal)),
		elapsed_ms => int(1000 * (($job->{finished} // _now()) - $job->{created})),
		result => summary($job->{result}), error => $job->{error}};
}

sub get ($self, $id) {
	my $state = $self->{state};
	lock $state;
	return exists $state->{jobs}{$id} ? _snapshot($state->{jobs}{$id}) : undef;
}

sub snapshot ($self) {
	my $state = $self->{state};
	lock $state;
	return {version => $state->{version}, pid => 0 + $$, runtime => 'single-slot',
		limits => {map { $_ => $self->{$_} } qw(workers max_active max_history max_bytes max_passes)},
		metrics => {map { $_ => $state->{$_} } qw(active accepted rejected completed failed cancelled closing)},
		workers => [map { {id => 0 + $_, job => $state->{workers}{$_}} } sort {$a <=> $b} keys %{$state->{workers}}],
		jobs => [map { _snapshot($state->{jobs}{$_}) } reverse @{$state->{order}}]};
}

sub cancel ($self, $id) {
	my $state = $self->{state};
	lock $state;
	my $job = $state->{jobs}{$id} // return undef;
	unless ($job->{terminal}) {
		lock $job->{token};
		$job->{token}{cancelled} = 1;
		$state->{version}++;
	}
	return _snapshot($job);
}

sub shutdown ($self) {
	return if $self->{stopped};
	my $state = $self->{state};
	{
		lock $state;
		$state->{closing} = 1;
		for my $job (values %{$state->{jobs}}) {
			next if $job->{terminal};
			lock $job->{token};
			$job->{token}{cancelled} = 1;
		}
	}
	if ($self->{started}) {
		$self->{input}->close;
		await $self->{producers};
		$self->{results}->close;
		await $self->{collector};
	}
	$self->{stopped} = 1;
}

1;
