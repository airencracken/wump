#!/usr/bin/env perl
use v5.42;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../perl/lib", "$FindBin::Bin/lib";
BEGIN {
	$ENV{MOJO_REACTOR} = 'Wump::Mojo::Reactor';
	$ENV{MOJO_NO_JSON_XS} = $ENV{MOJO_NO_TLS} = $ENV{MOJO_NO_NNR} = $ENV{MOJO_NO_SOCKS} = 1;
}
use Wump;
use WumpDemo::App;
use Mojo::Server::Daemon;
use Mojo::JSON 'encode_json';
use Getopt::Long 'GetOptions';

my ($listen, $workers, $max_active, $max_history, $jobs, $app, $loop, $server);
CHECK {
	# Getopt::Long compiles option-prefix regexes. Finish configuration before
	# Wump starts execution slots, while the ordinary compiler is available.
	($listen, $workers, $max_active, $max_history) = ('http://127.0.0.1:3000', 4, 8, 16);
	GetOptions('listen=s' => \$listen, 'workers=i' => \$workers,
		'max-active=i' => \$max_active, 'max-history=i' => \$max_history)
		or die "Usage: $0 [--listen http://127.0.0.1:3000] [--workers 4] [--max-active 8] [--max-history 16]\n";
	die "Unexpected arguments\n" if @ARGV;
	# Resolve plugins, generated helpers and the reactor before execution
	# slots start. The job service allocates its channels lazily on submit.
	$jobs = WumpDemo::Jobs->new(workers => $workers, max_active => $max_active, max_history => $max_history);
	$app = WumpDemo::App->new(jobs => $jobs);
	$app->static->warmup;
	$app->renderer->warmup;
	$loop = Mojo::IOLoop->singleton;
	$loop->reactor;
	$server = Mojo::Server::Daemon->new(app => $app, ioloop => $loop, listen => [$listen], silent => 1);
	# Socket setup also uses IO::Socket's dynamic regexes. Finish bootstrap
	# before the compiler is frozen; -c remains free of listening sockets.
	$server->start unless $^C;
}
my $stop = 0;
$SIG{INT} = sub { $stop = 1 };
$SIG{TERM} = sub { $stop = 1 };
$| = 1;
my $ok = eval {
	$server->start;
	my $port = $server->ports->[0];
	my $slots = Wump::execution_slots();
	print encode_json({event => 'ready', pid => 0 + $$, port => $port, workers => $workers,
		runtime => $slots > 1 ? 'parallel' : 'single-slot', execution_slots => $slots}), "\n";
	$loop->recurring(0.01 => sub { $loop->stop if $stop });
	$loop->start;
	1;
};
my $error = $@;
$server->stop;
$jobs->shutdown;
undef $server;
$loop->reset;
die $error unless $ok;
print encode_json({event => 'stopped', %{$jobs->snapshot->{metrics}}}), "\n";
