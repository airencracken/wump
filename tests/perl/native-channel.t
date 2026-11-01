use v5.42;
use strict;
use warnings;
use Test::More;
use B ();
use Scalar::Util qw(refaddr weaken);
use Wump;
use lib 'tests/perl/lib';
use WumpTest 'check_program';

for my $name (qw(send recv close)) {
	no strict 'refs';
	my $method = \&{"Wump::Channel::$name"};
	ok(B::svref_2object($method)->XSUB, "$name has a core entry rather than a Perl wrapper");
	ok(defined &{"Wump::_channel_$name"} && refaddr($method) == refaddr(\&{"Wump::_channel_$name"}),
		"$name resolves to its registered native entry");
}
my $ch = chan(4);
is(scalar $ch->send('one'), undef, 'scalar send returns undef');
is_deeply([7, $ch->send('two'), 9], [7,9], 'list send returns empty and preserves adjacent operands');
is(scalar $ch->recv, 'one', 'scalar receive returns the oldest value');
is_deeply([7, $ch->recv, 9], [7,'two',1,9], 'list receive returns value/status and preserves adjacent operands');
$ch->send(undef);
is_deeply([$ch->recv], [undef,1], 'undef remains a successful message');
is(scalar $ch->close, undef, 'scalar close returns undef');
is_deeply([$ch->recv], [undef,''], 'closed receive has false status');
is(scalar $ch->recv, undef, 'closed scalar receive returns undef');
my $list_close = chan();
is_deeply([3, $list_close->close, 5], [3,5], 'list close returns empty');

my $object = {message => 42};
$ch = chan(1);
$ch->send($object);
is(refaddr(scalar $ch->recv), refaddr($object), 'channel preserves reference identity');
my $text = 'before';
$ch->send($text);
$text = 'after';
is(scalar $ch->recv, 'before', 'send snapshots the scalar value');

my $weak;
{
	my $value = {temporary => 1};
	$weak = $value;
	weaken($weak);
	$ch->send($value);
}
ok(defined $weak, 'queued message owns its reference');
($ch->recv, ok(defined $weak, 'void receive retains its result through the caller statement'));
ok(!defined $weak, 'void receive releases the message after the statement');

{
	package NativeChannelValue;
	our ($fetches, $throw);
	sub TIESCALAR { bless [], shift }
	sub FETCH {
		$fetches++;
		my @grow = (1..8192);
		Wump::yield();
		die "payload fetch failed\n" if $throw;
		return 'magic value';
	}
}
tie my $payload, 'NativeChannelValue';
$NativeChannelValue::fetches = 0;
$ch->send($payload);
is(scalar $ch->recv, 'magic value', 'payload FETCH may grow the stack and yield');
is($NativeChannelValue::fetches, 1, 'send fetches its payload once');
$NativeChannelValue::throw = 1;
eval { $ch->send($payload) };
like($@, qr/payload fetch failed/, 'payload exception unwinds the native entry');
$NativeChannelValue::throw = 0;
$ch->send('after exception');
is(scalar $ch->recv, 'after exception', 'failed payload does not publish a message or corrupt the stack');

for my $case (
	[sub {$ch->send()}, qr/Usage: CHANNEL->send/],
	[sub {$ch->send(1,2)}, qr/Usage: CHANNEL->send/],
	[sub {$ch->recv(1)}, qr/Usage: CHANNEL->recv/],
	[sub {$ch->close(1)}, qr/Usage: CHANNEL->close/],
	[sub {Wump::Channel::recv('bad')}, qr/invalid channel/],
	[sub {Wump::Channel::send([],1)}, qr/invalid channel/],
) {
	eval { $case->[0]->() };
	like($@, $case->[1], 'native entry validates arity and receiver');
}
$ch->close;
eval { $ch->send(1) }; like($@, qr/send on closed channel/, 'closed send throws');
eval { $ch->close }; like($@, qr/close of closed channel/, 'duplicate close throws');
$ch = chan(1);
$ch->send(43);
eval '$ch->recv = 1';
like($@, qr/Can't modify non-lvalue subroutine call/, 'lvalue calls retain the upstream rejection');
is(scalar $ch->recv,43,'a rejected lvalue receive does not consume its message');

{
	package NativeChildChannel;
	our @ISA = ('Wump::Channel');
	sub send { my ($self,$value) = @_; $self->SUPER::send($value+1) }
	package NativeOtherObject;
	sub send { return ('custom', wantarray ? 'list' : 'scalar') }
	sub recv { return 73 }
	sub close { return 79 }
}
my $parent = chan(1);
my $child_id = $$parent;
my $child = bless \$child_id, 'NativeChildChannel';
$child->send(41);
is(scalar $child->recv, 42, 'subclass override and SUPER retain normal method resolution');
$child->close;
my $other = bless {}, 'NativeOtherObject';
is_deeply([$other->send(1)], ['custom','list'], 'unrelated send keeps its context and method body');
is(scalar $other->recv, 73, 'unrelated recv remains ordinary');
is(scalar $other->close, 79, 'unrelated close remains ordinary');

my $saved_send = Wump::Channel->can('send');
$ch = chan(2);
$saved_send->($ch, 17);
is(scalar $ch->recv, 17, 'a captured original method remains callable');
{
	no warnings 'redefine';
	*Wump::Channel::send = sub { my ($self,$value)=@_; $saved_send->($self,$value+2) };
	$ch->send(19);
	is(scalar $ch->recv, 21, 'a replacement method CV is never bypassed');
	*Wump::Channel::send = $saved_send;
}
$ch->send(23);
is(scalar $ch->recv, 23, 'method cache observes restoration of the original CV');

# Implicit @_ and goto must keep the upstream XS argument adapter.
sub forwarded_send { &Wump::Channel::send }
sub tail_send { goto &Wump::Channel::send }
forwarded_send($ch, 29);
tail_send($ch, 31);
is_deeply([scalar $ch->recv, scalar $ch->recv], [29,31], 'implicit forwarding and tail calls preserve arguments');

check_program(q{
	use Wump;
	CHECK {
		no warnings 'redefine';
		*Wump::_send = *Wump::_recv = *Wump::_close = sub { die "compatibility XS symbol entered\n" };
	}
	my $ch=chan(1);
	$ch->send(42);
	die "bad result" unless $ch->recv == 42;
	$ch->close;
	print "native channel symbols bypassed\n";
}, 0, qr/native channel symbols bypassed/, 'native methods bypass replaced compatibility symbols');
check_program(q{
	BEGIN { $ENV{WUMPPROCS}=4 }
	use Wump;
	my ($work,$out)=(chan(7),chan());
	for (1..8) {
		act {
			while (1) {
				my ($id,$ok)=$work->recv;
				last unless $ok;
				yield;
				$out->send($id*$id);
			}
		}
	}
	act { $work->send($_) for 1..256; $work->close };
	my $sum=0;
	$sum += $out->recv for 1..256;
	die "bad sum" unless $sum == 256*257*513/6;
	print "parallel native channels verified\n";
}, 0, qr/parallel native channels verified/, 'native calls migrate and exchange every message on four slots');
check_program(q{
	BEGIN { undef &Wump::_channel_send }
	use Wump;
	use B ();
	for my $name (qw(send recv close)) {
		no strict 'refs';
		my $method=B::svref_2object(\&{"Wump::Channel::$name"});
		die "changed fallback CV" if $method->XSUB || $method->GV->NAME ne $name
			|| $method->GV->STASH->NAME ne 'Wump::Channel';
	}
	my $ch=chan(1);
	$ch->send(42);
	die "bad fallback" unless $ch->recv==42;
	$ch->close;
	print "named compatibility methods verified\n";
}, 0, qr/named compatibility methods verified/, 'controls without native entries retain the original named wrappers');
done_testing;
