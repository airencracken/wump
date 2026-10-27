use v5.42;
use strict;
use warnings;
use Wump;

scope {
	my $payload = {visits => 0};
	say 'before send: ', Wump::is_shared($payload) ? 'shared' : 'unclassified';
	my $messages = chan(1);
	$messages->send($payload);
	say 'after send: ', Wump::is_shared($payload) ? 'shared' : 'unclassified';
	my $received = $messages->recv;
	my $done = chan;
	act {
		lock $received;
		yield;
		$received->{visits}++;
		$done->send(Wump::is_shared($received));
	};
	say 'child sees publication: ', 0 + $done->recv;
	say "shared visits: $payload->{visits}";
};
