use v5.42;
use strict;
use warnings;
use Test::More;

my @switches = map { "-I$_" } @INC;
sub program ($code, $status, $pattern, $name) {
	open my $child, '-|', $^X, @switches, '-e',
		q{BEGIN { open STDERR, '>&', STDOUT or die $! } } . $code
		or die "spawn $name: $!";
	my $output = do { local $/; <$child> };
	close $child;
	is($?, $status << 8, "$name: wait status");
	like($output, $pattern, "$name: output");
}

program(q{
	use Wump;
	my $out = chan;
	my $ran = 0;
	my @result = act { $ran = 1; $out->send(42) };
	print "spawn:$ran:" . scalar(@result) . "\n";
	print 'result:' . $out->recv . "\n";
}, 0, qr/\Aspawn:0:0\nresult:42\n\z/, 'top-level main act spawns asynchronously and receives');

program(q{
	use Wump;
	print defined(&main::run) || defined(&Wump::run) || defined(&Wump::_run) ? 'present' : 'absent';
}, 0, qr/\Aabsent\z/, 'run wrapper is removed from the public and private bridge');

program(q{
	use Wump;
	act { print "queued child ran\n" };
	print "main returned\n";
}, 0, qr/\Amain returned\n\z/, 'main return abandons queued work');

program(q{
	use Wump;
	package Owned { sub DESTROY { print "released\n" } }
	my $park = chan;
	act { my $owned = bless {}, 'Owned'; print "started\n"; $park->recv; print "finished\n" };
	yield;
	print "main returned\n";
}, 0, qr/\Astarted\nmain returned\nreleased\n\z/, 'main return unwinds parked acts');

program(q{
	use Wump;
	my @seen;
	scope {
		act { yield; push @seen, 'child'; act { yield; push @seen, 'grandchild' } };
		scope { act { push @seen, 'nested' } };
	};
	print join(',', sort @seen), "\n";
}, 0, qr/\Achild,grandchild,nested\n\z/, 'scope waits for children and descendants across nested scopes');

program(q{
	use Wump;
	my $park = chan;
	act { $park->recv; print "unrelated completed\n" };
	for (1..100) { scope { act { yield }; yield; act {} } }
	print "scopes completed\n";
}, 0, qr/\Ascopes completed\n\z/, 'scope does not wait for unrelated acts and supports repeated completion');

program(q{
	use Wump;
	my $out = chan(1);
	eval { scope { act { $out->send(7) }; die "caught\n" } };
	print $@;
	print scalar($out->recv), "\n";
	scope { act { print "still usable\n" } };
}, 0, qr/\Acaught\n7\nstill usable\n\z/, 'scope body exceptions restore the parent scope');

program(q{
	use Wump;
	my @seen;
	scope {
		act {
			eval { scope { act { sleep 0.001; push @seen, 'grandchild' }; die "caught\n" } };
			push @seen, 'parent';
		};
	};
	print join(',', sort @seen), "\n";
}, 0, qr/\Agrandchild,parent\n\z/, 'outer scope waits for descendants of a failed nested scope');

program(q{
	use Wump;
	my $out = chan;
	for my $values ([3, 1, 2], [8, 7, 9]) {
		act { my @sorted = sort { yield; $a <=> $b } @$values; $out->send(join(',', @sorted)) };
	}
	my @root = sort { yield; $a <=> $b } (6, 4, 5);
	my @children = (scalar $out->recv, scalar $out->recv);
	print join(',', @root), ':', join(':', sort @children), "\n";
}, 0, qr/\A4,5,6:1,2,3:7,8,9\n\z/, 'yielding sort comparisons isolate main and child operands');

program(q{
	use Wump;
	my $out = chan(1);
	$! = 11;
	{
		local $! = 22;
		act { local $! = 33; yield; $out->send(0 + $!) };
		yield;
		print 0 + $!, ':';
	}
	print 0 + $!, ':';
	print scalar($out->recv), ':';
	eval { local $! = 44; die "caught\n" };
	print 0 + $!, ':';
	{ local $^E = 55; yield; print 0 + $^E, ':' }
	print 0 + $!, "\n";
}, 0, qr/\A22:11:33:11:55:11\n\z/, 'native errno localization survives yields and exception unwind');

program(q{
	use Wump;
	my $out = chan;
	eval { act { die "child panic\n" }; $out->recv };
	print "should not return\n";
}, 2, qr/\Atask 2 \[panic\]: child panic\n\z/, 'child panic cannot be caught by main eval');

program(q{ use Wump; my $ch = chan; $ch->recv }, 2,
	qr/Wump: runtime failed:/, 'top-level deadlock reports a process failure');
program(q{ use Wump; die "main panic\n" }, 2,
	qr/\Atask 1 \[panic\]: main panic\n\z/, 'uncaught main die follows act panic semantics');
program(q{ use Wump; END { print "END\n" } exit 7 }, 7,
	qr/\AEND\n\z/, 'explicit main exit preserves status and END blocks');
program(q{ use Wump; INIT { print "INIT\n" } END { print "END\n" } print "main\n" }, 0,
	qr/\AINIT\nmain\nEND\n\z/, 'interpreter phase ordering is preserved');
program(q{
	use Wump;
	our $out;
	INIT { $out = chan(1) }
	END { 'last match' =~ /(match)/; act { $out->send(42) }; print scalar($out->recv), ":$1\n" }
}, 0, qr/\A42:match\n\z/, 'END can schedule and retain its match state before shutdown');
program(q{
	use Wump;
	use warnings;
	$? = 256;
	my $out = chan(1);
	{ local $?; print "$?:"; $? = 512; act { $? = 768; yield; $out->send($?) }; yield; print "$?:" }
	print "$?:", scalar($out->recv), "\n";
}, 0, qr/\A0:512:256:768\n\z/, 'child status and local restoration are isolated between acts');
program(q{ use Wump; BEGIN { eval { chan() }; print $@ } }, 0,
	qr/Wump: chan requires a running task/, 'compile-time code cannot schedule');
program(q{ require Wump; eval { Wump->import }; print $@ }, 0,
	qr/Wump: enable with use Wump before program execution/, 'runtime import fails explicitly');
program(q{ print "ordinary Perl\n"; exit 3 }, 3,
	qr/\Aordinary Perl\n\z/, 'ordinary scripts keep their upstream entry behavior');

done_testing;
