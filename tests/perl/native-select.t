use v5.42;
use strict;
use warnings;
use Test::More;
use B ();
use B::Deparse;
use Scalar::Util qw(refaddr weaken);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
BEGIN { CLOCK_MONOTONIC() }
use Wump;
use lib 'tests/perl/lib';
use WumpTest 'check_program';

sub names ($code) {
	my @names;
	my $walk;
	$walk = sub ($op) {
		while ($$op) {
			push @names, $op->name;
			$walk->($op->first) if $op->can('first');
			$op = $op->sibling;
		}
	};
	$walk->(B::svref_2object($code)->ROOT);
	return \@names;
}
my $native = sub { sel([], 0) };
my $implicit = sub { sel([]) };
for my $code ($native, $implicit) {
	ok(grep($_ eq 'wumpsel', @{names($code)}), 'imported selection compiles as a native operation');
	ok(!grep($_ eq 'entersub', @{names($code)}), 'selection bypasses function dispatch');
	my $text = B::Deparse->new->coderef2text($code);
	my $copy = eval "use Wump; sub $text";
	is($@, '', 'deparsed selection compiles');
	ok(grep($_ eq 'wumpsel', @{names($copy)}), 'deparse retains native selection');
}
my $optout;
{ no Wump; $optout = sub { sel([], 0) } }
for my $code (sub { Wump::sel([],0) }, sub { &sel([],0) }, $optout) {
	ok(!grep($_ eq 'wumpsel', @{names($code)}), 'qualified, ampersand and lexical opt-out calls retain dispatch');
}
for my $call (sub { sel([],0) }, sub { Wump::sel([],0) }, sub { Wump::_sel([],0) }) {
	is_deeply([$call->()], [undef,undef,''], 'empty default returns no winner');
	is(scalar $call->(), undef, 'empty scalar default returns undef');
}
is_deeply([11,sel([],0),13], [11,undef,undef,'',13], 'list selection preserves neighboring operands');
my $start = clock_gettime(CLOCK_MONOTONIC);
is_deeply([sel([],0.002)], [undef,undef,''], 'empty timed selection expires');
cmp_ok(clock_gettime(CLOCK_MONOTONIC)-$start, '>=', 0.001, 'positive timeout does not return immediately');

my $ch = chan(3);
$ch->send('one'); $ch->send(undef); $ch->close;
is_deeply([sel([['recv',$ch]])], [0,'one',1], 'receive selects case zero and the oldest message');
is_deeply([sel([['recv',$ch]])], [0,undef,1], 'undef message remains successful');
is_deeply([sel([['recv',$ch]])], [0,undef,''], 'closed drained receive is a selected false result');
is(scalar sel([['recv',$ch]]), 0, 'scalar result is the defined case index, including zero');
is_deeply([sel([['recv',undef],['send',undef,42]],0)], [undef,undef,''], 'undefined channels disable cases');
$ch = chan(1);
is_deeply([sel([['send',$ch,42]],0)], [0,undef,1], 'selected buffered send reports success');
is(scalar $ch->recv,42,'selected send publishes its payload');
my $value = {identity=>1};
sel([['send',$ch,$value]]);
is(refaddr(scalar $ch->recv),refaddr($value),'selected send retains reference identity');
my $text = 'before';
sel([['send',$ch,$text]]); $text='after';
is(scalar $ch->recv,'before','selected send copies a scalar head');
my $weak;
{
	my $payload={temporary=>1}; $weak=$payload; weaken($weak);
	$ch->send($payload);
}
(sel([['recv',$ch]]),ok(defined $weak,'void receive retains its value to the end of the statement'));
ok(!defined $weak,'void receive releases its result after the statement');

# Losing sends and snapshots must not accumulate until runtime shutdown.
for (1..40) {
	my $payload={loser=>$_}; $weak=$payload; weaken($weak);
	my $blocked=chan();
	sel([['send',$blocked,$payload]],0);
	undef $payload;
	ok(!defined $weak,'default releases losing send candidate and snapshot');
}
$ch=chan(1); $ch->close;
eval { sel([['send',$ch,1]],0) };
like($@,qr/send on closed channel/,'selected closed send throws');
for my $duration (undef,-2,'garbage','NaN','Inf',[],1e30) {
	eval { sel([],$duration) };
	like($@,qr/(invalid selection timeout|selection timeout requires a plain scalar)/,'invalid timeout rejects before selecting');
}
for my $bad (undef,{},[undef],[[]],[['bad',undef]],[['recv',undef,1]],[['send',undef]],[['recv',42]]) {
	my $ready=chan(1);
	my $cases = ref($bad) eq 'ARRAY' ? [['send',$ready,99],@$bad] : $bad;
	eval { sel($cases,0) };
	like($@,qr/Wump: (?:selection requires|invalid selection|invalid channel)/,'malformed selection rejects');
	is(scalar sel([['recv',$ready]],0),undef,'validation error commits no earlier ready send');
}
$ch=chan(1); $ch->send(73);
my @many = ((map {['recv',undef]} 1..16),['recv',$ch]);
is_deeply([sel(\@many,0)],[16,73,1],'heap-sized selection preserves disabled case indices');
$ch=chan(1); $ch->send(79);
my ($which,$got,$ok)=sel([['recv',$ch],['recv',$ch]],0);
ok(defined($which) && $which<=1 && $got==79 && $ok,'duplicate receive cases consume exactly one message');
is(scalar sel([['recv',$ch]],0),undef,'duplicate loser consumes nothing');
$ch=chan();
is(scalar sel([['send',$ch,1],['recv',$ch]],0),undef,'a selector does not rendezvous with itself');

{
	package SelectTied;
	our $fetches=0;
	sub TIEARRAY { bless [],shift }
	sub TIESCALAR { bless [],shift }
	sub FETCHSIZE { $fetches++; die "unexpected FETCHSIZE\n" }
	sub FETCH { $fetches++; die "unexpected FETCH\n" }
}
tie my @outer,'SelectTied';
tie my @row,'SelectTied';
tie my $field,'SelectTied';
my $fields=['recv',undef];
tie $fields->[0],'SelectTied';
my $weak_case=['recv',undef];
my $weak_outer=[$weak_case]; weaken($weak_outer->[0]);
for my $cases (\@outer,[\@row],$fields,[$fields],$weak_outer,[bless(['recv',undef],'SelectBlessed')]) {
	eval { sel($cases,0) };
	like($@,qr/Wump: (?:selection requires|invalid selection)/,'unsupported control magic rejects');
}
is($SelectTied::fetches,0,'descriptor validation invokes no tied callbacks');
{
	my $cases=[['recv',undef]];
	local $cases->[0]=['recv',undef];
	eval {sel($cases,0)};
	like($@,qr/selection requires plain/,'active outer-array element views reject before selecting');
}
{
	my $row=['recv',undef];
	local $row->[1]=undef;
	eval {sel([$row],0)};
	like($@,qr/selection requires plain/,'active descriptor element views reject before selecting');
}
$ch=chan(1); sel([['send',$ch,83]],0);
is_deeply([sel([['recv',$ch]],0)],[0,83,1],'runtime remains usable after validation failures');

check_program(q{
	use Wump;
	CHECK {
		no warnings qw(redefine prototype);
		*sel=*Wump::sel=*Wump::_sel=sub {die "wrapper entered\n"};
	}
	my $ch=chan(1);
	sel([['send',$ch,42]]);
	my ($i,$v,$ok)=sel([['recv',$ch]],0);
	die "bad result" unless defined($i) && $i==0 && $v==42 && $ok;
	print "native selection bypass verified\n";
},0,qr/native selection bypass verified/,'native selection bypasses replaced wrappers and XS');
check_program(q{
	use Wump;
	use Opcode qw(opset opmask_add);
	BEGIN { opmask_add(opset('wumpsel')) }
	sel([],0);
},255,qr/'Wump channel selection' trapped by operation mask/,'selection honors upstream opcode masks');
for my $source ('sel()','sel([],0,1)') {
	eval "sub { $source }";
	like($@,qr/(Not enough|Too many) arguments/,'native selection retains prototype arity checks');
}
check_program(q{
	use Wump;
	BEGIN { no warnings qw(redefine prototype); *sel=sub :prototype($;$) {return 97} }
	die "replacement bypassed" unless sel([],0)==97;
	print "replacement retained\n";
},0,qr/replacement retained/,'replacement CV does not inherit the native checker');

for my $slots (1,4) {
	check_program('BEGIN { $ENV{WUMPPROCS}=' . $slots . ' }' . q{
		use Wump;
		my ($work,$out,$done)=(chan(),chan(),chan());
		for (1..8) {
			act {
				while (1) {
					my ($i,$id,$ok)=sel([['recv',$work],['recv',$done]]);
					last if $i==1 || !$ok;
					sel([['send',$out,$id*$id]]);
				}
			};
		}
		act { sel([['send',$work,$_]]) for 1..256; $work->close };
		my $sum=0;
		for (1..256) {my ($i,$v,$ok)=sel([['recv',$out]],1); die "timeout" unless $ok; $sum+=$v}
		die "bad sum" unless $sum==256*257*513/6;
		$done->close;
		print "parallel selection verified\n";
	},0,qr/parallel selection verified/,'selection rendezvous transfers every message on '.$slots.' slots');
	check_program('BEGIN { $ENV{WUMPPROCS}=' . $slots . ' }' . q{
		use Wump;
		my ($work,$out)=(chan(),chan());
		act {
			for (1..512) {
				my $id=$work->recv;
				sel([['send',$out,$id+1]]);
				my ($i,$again,$ok)=sel([['recv',$work]]);
				die "lost plain send" unless $ok && $again==$id+2;
				$out->send($again+1);
			}
		};
		for (1..512) {
			my $id=$_*4;
			sel([['send',$work,$id]]);
			die "lost selected send" unless $out->recv==$id+1;
			$work->send($id+2);
			my ($i,$v,$ok)=sel([['recv',$out]]);
			die "lost selected receive" unless $ok && $v==$id+3;
		}
		print "plain interop verified\n";
	},0,qr/plain interop verified/,'selection interoperates with normal channel methods on '.$slots.' slots');
	check_program('BEGIN { $ENV{WUMPPROCS}=' . $slots . ' }' . q{
		use Wump;
		my ($done,$work,$ack)=(chan(),chan(),chan());
		act {
			my ($i,$v,$ok)=sel([['recv',$work],['recv',$done]]);
			die "wrong cancellation" unless $i==1 && !$ok;
			$ack->send(1);
		};
		yield;
		$done->close;
		$ack->recv;
		die "orphan receive" if defined scalar sel([['send',$work,1]],0);
		sel([['send',$work,1]],0.001);
		die "orphan timed send" if defined scalar sel([['recv',$work]],0);
		sel([['recv',$work]],0.001);
		die "orphan timed receive" if defined scalar sel([['send',$work,1]],0);
		my $blocked=chan();
		act { my ($i,$v,$ok)=sel([['recv',$blocked]]); die "wrong closed receive" if $ok; $ack->send(1) };
		yield; $blocked->close; $ack->recv;
		$blocked=chan();
		act { eval { sel([['send',$blocked,1]]) }; die "missing closed send" unless $@ =~ /send on closed channel/; $ack->send(1) };
		yield; $blocked->close; $ack->recv;
		print "cancellation and closure verified\n";
	},0,qr/cancellation and closure verified/,'done-channel cancellation removes losing waiters on '.$slots.' slots');
}
check_program(q{
	use Wump;
	my ($target,$changed,$out)=(chan(),chan(),chan());
	my $cases=[['send',$target,101]];
	act { sel($cases); $out->send(1) };
	yield;
	$cases->[0]=['recv',$changed];
	die "snapshot lost" unless $target->recv==101;
	$out->recv;
	print "snapshot verified\n";
},0,qr/snapshot verified/,'parked selection retains its original descriptors');
check_program(q{
	use Wump;
	my $ack=chan();
	for (1..32) {
		my $blocked=chan();
		act { $ack->send(1); sel([(map {['recv',undef]} 1..9),['send',$blocked,{abandoned=>1}]],10) };
		$ack->recv;
	}
	yield;
	print "abandoned selectors detached\n";
},0,qr/abandoned selectors detached/,'shutdown cancels pending heap and timer ownership before Perl unwind');
done_testing;
