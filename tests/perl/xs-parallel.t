use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		our $upgraded;
		BEGIN { $upgraded = 'ascii'; utf8::upgrade($upgraded) }
		my ($wide, $bytes) = ("\x{100}", 'bytes');
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..128) {
					die "UTF-8 query lost encoding\n" unless utf8::is_utf8($wide) && utf8::is_utf8($upgraded);
					die "UTF-8 query changed plain inputs\n" if utf8::is_utf8($bytes) || utf8::is_utf8(123) || utf8::is_utf8(undef);
					yield;
				}
				$out->send(1);
			};
		}
		die "missing UTF-8 query workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			{ package Utf8QueryTie; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "UTF-8 query called FETCH\n" } }
			tie my $value, 'Utf8QueryTie';
			eval { utf8::is_utf8($value) };
			die "UTF-8 query admitted magic: $@" unless $@ =~ /requires a nonmagical value/;
			eval { utf8::valid($wide) };
			die "UTF-8 query admitted other entries: $@" unless $@ =~ /XS function has not declared parallel safety/;
		}
		die "UTF-8 query failed after rejection\n" unless utf8::is_utf8($wide);
		print "UTF-8 flag queries preserve encoding and admission\n";
	}, 0, qr/\AUTF-8 flag queries preserve encoding and admission\n\z/,
		"UTF-8 flag queries run on $slots slots with shared inputs and recovery");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use Socket qw(:all);
		our ($address, $address6, $numeric, $nohost, $noserv);
		BEGIN {
			$address = pack_sockaddr_in(4321, inet_aton('127.0.0.1'));
			$address6 = pack_sockaddr_in6(4321, inet_pton(AF_INET6, '::1'));
			$numeric = NI_NUMERICHOST | NI_NUMERICSERV;
			$nohost = NIx_NOHOST; $noserv = NIx_NOSERV;
		}
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					my ($error, $host, $service) = getnameinfo($address, $numeric);
					die "numeric socket metadata changed\n" if $error || $host ne '127.0.0.1' || $service ne '4321';
					($error, $host, $service) = getnameinfo($address6, $numeric);
					die "numeric IPv6 metadata changed\n" if $error || $host ne '::1' || $service ne '4321';
					($error, $host, $service) = getnameinfo($address, $numeric, $nohost);
					die "no-host metadata changed\n" if $error || defined($host) || $service ne '4321';
					($error, $host, $service) = getnameinfo($address, $numeric, $noserv);
					die "no-service metadata changed\n" if $error || $host ne '127.0.0.1' || defined($service);
					yield;
				}
				$out->send(1);
			};
		}
		die "missing socket metadata workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			for my $call (sub { getnameinfo($address, 0) },
				sub { getnameinfo($address, $numeric, 4) }) {
				eval { $call->() };
				die "resolver policy bypassed: $@" unless $@ =~ /numeric host and service/;
			}
			for my $invalid ('short', substr($address, 0, -1), "$address\0", substr($address6, 0, -1), "$address6\0") {
				my $bytes = "$invalid";
				eval { getnameinfo($bytes, $numeric) };
				die "invalid socket address admitted: $@" unless $@ =~ /IPv4 or IPv6 sockaddr/;
			}
			for my $invalid (0.5, 'numeric', [], 1 << 63) {
				eval { getnameinfo($address, $invalid) };
				die "invalid socket flags admitted: $@" unless $@ =~ /requires plain/;
			}
			{ package SocketTie; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "socket metadata called FETCH\n" } }
			tie my $bad, 'SocketTie';
			for my $call (sub { getnameinfo($bad, $numeric) }, sub { getnameinfo($address, $bad) }) {
				eval { $call->() };
				die "magical socket input admitted: $@" unless $@ =~ /requires plain/;
			}
			eval { getaddrinfo('localhost', 'http') };
			die "socket audit admitted DNS: $@" unless $@ =~ /XS function has not declared parallel safety/;
		}
		my ($error, $host, $service) = getnameinfo($address, $numeric);
		die "socket metadata did not recover\n" if $error || $host ne '127.0.0.1' || $service ne '4321';
		print "numeric socket metadata preserved outputs and resolver policy\n";
	}, 0, qr/\Anumeric socket metadata preserved outputs and resolver policy\n\z/,
		"numeric nameinfo runs on $slots slots with shared input and failure recovery");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use Time::HiRes ();
		{ package CanRoot;
			sub inherited { Wump::yield(); return 'root' }
			sub replacement { return 'replacement' }
			sub AUTOLOAD { die "can invoked AUTOLOAD\n" }
			sub DESTROY { }
			BEGIN { no strict 'refs'; *{"CanRoot::caf\x{e9}"} = sub { return 'unicode' } }
		}
		{ package CanChild; our @ISA; BEGIN { @ISA = ('CanRoot') } sub own { return 'child' } }
		{ package CanOther; sub inherited { return 'other' } }
		{ package CanColdRoot; sub cold { Wump::yield(); return 'cold' } }
		{ package CanColdChild; our @ISA = ('CanColdRoot') }
		our @expected;
		sub cases {
			return ([undef, 'own'], ['', 'own'], [!!0, 'own'],
				['CanChild', 'own'], ['CanChild', 'inherited'], ['CanChild', 'missing'],
				['CanUnknown', 'can'], ['CanUnknown', 'missing'],
				[bless({}, 'CanChild'), 'inherited'], [[], 'own'],
				['CanChild', "caf\x{e9}"], ['CanChild', "own\0suffix"],
				['CanChild', 'CanRoot::inherited'], ['CanChild', 123], [123, 'can'],
				[\*STDOUT, 'can']);
		}
		BEGIN { @expected = map { defined UNIVERSAL::can(@$_) ? 1 : 0 } cases() }
		my ($class, $name) = ('CanChild', 'inherited');
		my $shared_object = bless {}, 'CanChild';
		my $out = chan(4);
		for (1..8) {
			act {
				my @cases = cases();
				RootFixture::executor_rendezvous();
				die "cold capability lookup failed\n" unless CanColdChild->can('cold')->('CanColdChild') eq 'cold';
				die "cold negative cache failed\n" if CanColdChild->can('absent');
				for (1..32) {
					for my $i (0..$#cases) {
						my $method = UNIVERSAL::can(@{$cases[$i]});
						die "can result changed at $i\n" unless (defined($method) ? 1 : 0) == $expected[$i];
						die "can returned an unpublished method\n" if defined($method)
							&& Wump::execution_slots() > 1 && !Wump::is_shared($method);
					}
					my $method = $class->can($name);
					die "can returned the wrong inherited method\n" unless $method->($shared_object) eq 'root';
					die "object can differs from class can\n" unless $shared_object->can($name) == $method;
					yield;
				}
				$out->send(1);
			};
		}
		die "missing capability workers\n" if grep { $out->recv != 1 } 1..8;
		my $object = bless {}, 'CanChild';
		my $method = $object->can('inherited');
		die "returned method lost ownership\n" unless $method->($object) eq 'root';
		@CanChild::ISA = ('CanOther');
		die "can ignored inheritance invalidation\n" unless $object->can('inherited')->($object) eq 'other';
		@CanChild::ISA = ('CanRoot');
		die "can ignored restored inheritance\n" unless $object->can('inherited')->($object) eq 'root';
		die "can invented a missing method\n" if $object->can('missing');
		{ no warnings 'once'; *CanRoot::missing = \&CanRoot::replacement }
		die "can retained a stale negative cache\n" unless $object->can('missing')->($object) eq 'replacement';
		my $warnings = 0;
		{
			local $SIG{__WARN__} = sub {
				my @padding = (1) x 20000;
				Wump::yield();
				$warnings++;
			};
			die "undefined method unexpectedly resolved\n" if $object->can(undef);
		}
		die "undefined method warning disappeared\n" unless $warnings == 1;
		{
			local $SIG{__WARN__} = sub { Wump::yield(); die "capability warning failed\n" };
			eval { $object->can(undef) };
			die "can lost the warning exception: $@" unless $@ =~ /capability warning failed/;
		}
		eval { UNIVERSAL::can('CanChild') };
		die "can accepted missing arguments: $@" unless $@ =~ /Usage:/;
		if (Wump::execution_slots() > 1) {
			{ package CanTie; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "can called FETCH\n" } }
			tie my $tied, 'CanTie';
			eval { UNIVERSAL::can($tied, 'own') };
			die "can admitted magical receiver: $@" unless $@ =~ /requires a plain scalar or reference/;
			eval { $object->can($tied) };
			die "can admitted magical method: $@" unless $@ =~ /requires a plain scalar/;
			eval { $object->can([]) };
			die "can admitted reference method: $@" unless $@ =~ /requires a plain scalar/;
			my $unsafe = Time::HiRes->can('usleep');
			eval { $unsafe->(0) };
			die "can bypassed native admission: $@" unless $@ =~ /XS function has not declared parallel safety: Time::HiRes::usleep/;
		}
		die "can did not recover after rejection\n" unless $object->can('own')->($object) eq 'child';
		print "capability lookup retained native results and released guards\n";
	}, 0, qr/\Acapability lookup retained native results and released guards\n\z/,
		"capability lookup handles shared inputs, caches and recovery on $slots slots");
}

WumpTest::check_program(q{
	use Wump ();
	BEGIN {
		eval { Wump::execution_slots() };
		die "compile-time slot query admitted: $@" unless $@ =~ /requires a running act/;
	}
	print "slot query requires an act\n";
}, 0, qr/\Aslot query requires an act\n\z/, 'slot reporting rejects calls before scheduler startup');

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use Time::HiRes (); use RootFixture;
		sub target ($id) { my $saved = $id; Wump::yield(); die "tail pad changed\n" unless $saved == $id; return $saved }
		sub tail { goto &target }
		sub clock_tail { goto &Time::HiRes::time }
		sub unsafe_tail { goto &Time::HiRes::usleep }
		my $out = chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..64) {
					die "tail arguments changed\n" unless tail($id) == $id;
					die "audited tail clock failed\n" unless clock_tail() > 0;
				}
				$out->send(1);
			};
		}
		die "missing tail callers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			eval { unsafe_tail(0) };
			die "tail bypassed XS safety: $@" unless $@ =~ /XS function has not declared parallel safety: Time::HiRes::usleep/;
		}
		print "tail calls retain private pads and native safety checks\n";
	}, 0, qr/\Atail calls retain private pads and native safety checks\n\z/,
		"tail calls preserve argument state and native admission on $slots slots");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use mro (); use RootFixture;
		{ package NextRoot; sub walk { Wump::yield(); return 'root' }
			sub inspect { return 'root capability' } sub replacement { return 'replacement' } }
		{ package NextLeft; our @ISA = ('NextRoot');
			sub walk { return 'left/' . shift->next::method() } }
		{ package NextRight; our @ISA = ('NextRoot');
			sub walk { return 'right/' . shift->next::method() } }
		{ package NextChild; our @ISA = ('NextLeft', 'NextRight');
			sub walk { return 'child/' . shift->next::method() }
			sub absent { return shift->maybe::next::method() }
			sub missing { return shift->next::method() }
			sub inspect { return shift->next::can() }
			sub absent_can { return shift->next::can() }
		}
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				my $object = bless {}, 'NextChild';
				for (1..32) {
					die "next method chain changed\n" unless $object->walk eq 'child/left/right/root';
					die "negative next cache changed\n" if defined $object->absent;
					my $method = $object->inspect;
					die "next can lost a method\n" unless ref($method) eq 'CODE';
					die "next can returned an unpublished method\n" if
						Wump::execution_slots() > 1 && !Wump::is_shared($method);
					die "next can returned the wrong method\n" unless $method->($object) eq 'root capability';
					die "next can invented a method\n" if defined $object->absent_can;
					eval { $object->missing };
					die "missing method error changed: $@" unless $@ =~ /No next::method 'missing'/;
					yield;
				}
				$out->send(1);
			};
		}
		die "missing method workers\n" if grep { $out->recv != 1 } 1..8;
		eval { mro::_nextcan('NextChild', 1) };
		die "non-method context admitted: $@" unless $@ =~ /must be used in method context/;
		if (Wump::execution_slots() > 1) {
			eval { mro::_nextcan() };
			die "missing arguments admitted: $@" unless $@ =~ /Usage:/;
			{ package NextTie; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "next lookup called FETCH\n" } }
			tie my $class, 'NextTie';
			eval { mro::_nextcan($class, 0) };
			die "magical next input admitted: $@" unless $@ =~ /requires a plain scalar or reference/;
			eval { mro::_nextcan('NextChild', $class) };
			die "magical next flag admitted: $@" unless $@ =~ /requires a plain scalar/;
			eval { mro::invalidate_all_method_caches() };
			die "unaudited mro mutator admitted: $@" unless $@ =~ /XS function has not declared parallel safety/;
		}
		die "next cache did not recover\n" unless NextChild->walk eq 'child/left/right/root';
		@NextChild::ISA = ('NextRoot');
		die "next cache ignored inheritance update\n" unless NextChild->walk eq 'child/root';
		@NextChild::ISA = ('NextLeft', 'NextRight');
		die "next cache ignored restored inheritance\n" unless NextChild->walk eq 'child/left/right/root';
		{ no warnings 'once'; *NextRoot::missing = \&NextRoot::replacement }
		die "negative next cache ignored method update\n" unless NextChild->missing eq 'replacement';
		print "next method caches retained context and released guards\n";
	}, 0, qr/\Anext method caches retained context and released guards\n\z/,
		"next-method lookup runs on $slots slots with cold, negative and exception paths");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use File::Spec::Functions (); use RootFixture;
		no warnings 'uninitialized';
		sub path_cases {
			return ([], [''], ['a'], ['a', 'b'], ['a//', './b', 'c/./'],
				['/', '..', 'a'], ['', 'a'], ['a', '', 'b'], [123, 456],
				[!!1, !!0], ["\x{100}", './x'], ["a\0b", 'c'], [undef, 'x'], ['x', undef]);
		}
		our (@expected, @trace, @expected_trace);
		{ package TracePath;
			use overload '""' => sub { push @main::trace, ${$_[0]}; return ${$_[0]} }, fallback => 1;
		}
		BEGIN {
			@expected = map { [File::Spec::Functions::catfile(@$_),
				File::Spec::Functions::catdir(@$_)] } path_cases();
			my ($base, $leaf) = ('base', 'leaf');
			my @parts = (bless(\$base, 'TracePath'), bless(\$leaf, 'TracePath'));
			@trace = ();
			File::Spec::Functions::catfile(@parts);
			$expected_trace[0] = join ',', @trace;
			@trace = ();
			File::Spec::Functions::catdir(@parts);
			$expected_trace[1] = join ',', @trace;
		}
		{ package YieldPath;
			use overload '""' => sub { Wump::yield(); return ${$_[0]} }, fallback => 1;
		}
		{ package ThrowPath;
			use overload '""' => sub { Wump::yield(); die "path overload failed\n" }, fallback => 1;
		}
		{ package StackPath;
			use overload '""' => sub { my @padding = (1) x 20000; Wump::yield(); return 'grown' }, fallback => 1;
		}
		{ package EscapePath;
			our ($exposed, $ack);
			use overload '""' => sub {
				$exposed->send(\$_[0]);
				die "exposed native input was readable during conversion\n" unless $ack->recv == 1;
				Wump::yield();
				return "escaped\x{100}";
			}, fallback => 1;
		}
		my ($shared_base, $shared_leaf) = ('shared', "\x{100}");
		my $text = "object\x{100}";
		my $object = bless \$text, 'YieldPath';
		my $out = chan(4);
		for (1..8) {
			act {
				my @paths = path_cases();
				RootFixture::executor_rendezvous();
				for (1..32) {
					die "shared scalar join changed\n" unless
						File::Spec::Functions::catfile($shared_base, $shared_leaf) eq "shared/\x{100}";
					die "yielding object join changed\n" unless
						File::Spec::Functions::catfile('a', $object) eq "a/object\x{100}";
					die "yielding directory join changed\n" unless
						File::Spec::Functions::catdir('a', $object) eq "a/object\x{100}";
					for my $i (0..$#paths) {
						my @actual = (File::Spec::Functions::catfile(@{$paths[$i]}),
							File::Spec::Functions::catdir(@{$paths[$i]}));
						for my $kind (0, 1) {
							my $expected = $expected[$i][$kind];
							die "path join changed at $i/$kind\n" if defined($expected)
								? !defined($actual[$kind]) || $actual[$kind] ne $expected
								: defined($actual[$kind]);
						}
					}
					yield;
				}
				$out->send(1);
			};
		}
		die "missing path joiners\n" if grep { $out->recv != 1 } 1..8;
		my ($base, $leaf) = ('base', 'leaf');
		my @parts = (bless(\$base, 'TracePath'), bless(\$leaf, 'TracePath'));
		@trace = ();
		File::Spec::Functions::catfile(@parts);
		die "file coercion order changed\n" unless join(',', @trace) eq $expected_trace[0];
		@trace = ();
		File::Spec::Functions::catdir(@parts);
		die "directory coercion order changed\n" unless join(',', @trace) eq $expected_trace[1];
		my $stack_text = 'stack';
		my $stack_path = bless \$stack_text, 'StackPath';
		die "join lost a grown Perl stack\n" unless
			File::Spec::Functions::catdir('a', $stack_path, 'b') eq 'a/grown/b';
		die "blessed scalar value changed\n" unless
			File::Spec::Functions::catfile($$object, 'b') eq "object\x{100}/b";
		if (Wump::execution_slots() > 1) {
			$EscapePath::exposed = chan(1);
			$EscapePath::ack = chan(1);
			my $finished = chan(1);
			my $result = chan(1);
			act {
				my $alias = $EscapePath::exposed->recv;
				eval { my $value = $$alias };
				$EscapePath::ack->send($@ =~ /read overlaps mutation of a shared value/ ? 1 : 0);
				$finished->recv;
				my $value = $$alias;
				$result->send(ref($value) eq 'EscapePath' ? 1 : 0);
			};
			my $escape_text = 'escape';
			my $escape = bless \$escape_text, 'EscapePath';
			die "escaping overload result changed\n" unless
				File::Spec::Functions::catfile('a', $escape) eq "a/escaped\x{100}";
			$finished->send(1);
			die "native input claim outlived the call\n" unless $result->recv == 1;
			{ package JoinTie; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "native join called FETCH\n" } }
			tie my $path, 'JoinTie';
			for my $join (\&File::Spec::Functions::catfile, \&File::Spec::Functions::catdir) {
				eval { $join->($path, 'b') };
				die "magical join admitted: $@" unless $@ =~ /requires a plain scalar/;
				eval { $join->('a', $path) };
				die "trailing magical join admitted: $@" unless $@ =~ /requires a plain scalar/;
				my $bad = 'bad';
				eval { $join->('a', bless(\$bad, 'ThrowPath')) };
				die "overload exception changed: $@" unless $@ =~ /path overload failed/;
				my $reference = [];
				die "reference coercion changed\n" unless $join->('a', $reference) =~ m{\Aa/ARRAY\(0x[0-9a-f]+\)\z};
				die "join failed after rejection\n" unless $join->('a', 'b') eq 'a/b';
			}
			eval { File::Spec::Unix->catfile('a', 'b') };
			die "unaudited method admitted: $@" unless $@ =~ /XS function has not declared parallel safety/;
		}
		print "functional path joins retained scalar semantics\n";
	}, 0, qr/\Afunctional path joins retained scalar semantics\n\z/,
		"audited functional path joining runs on $slots slots with shared inputs and failure recovery");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use File::Spec::Unix (); use RootFixture;
		my @cases = (["a/./b//", "a/b"], ["/../../a", "/a"], ["./", "."],
			["", ""], [undef, undef], [123, "123"], ["\x{100}/./b", "\x{100}/b"],
			["a\0b/./c", "a\0b/c"]);
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					for my $case (@cases) {
						my $expected = $case->[1];
						for my $actual (File::Spec::Unix::_fn_canonpath($case->[0]),
							File::Spec::Unix->canonpath($case->[0])) {
							die "canonical path changed\n" if defined($expected)
								? !defined($actual) || $actual ne $expected : defined($actual);
						}
					}
					yield;
				}
				$out->send(1);
			};
		}
		die "missing path workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			{ package TiedPath; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "native path called FETCH\n" } }
			tie my $path, 'TiedPath';
			eval { File::Spec::Unix::_fn_canonpath($path) };
			die "magical path admitted: $@" unless $@ =~ /requires a plain scalar/;
			eval { File::Spec::Unix::_fn_canonpath([]) };
			die "reference path admitted: $@" unless $@ =~ /requires a plain scalar/;
		}
		print "native path normalization retained scalar semantics\n";
	}, 0, qr/\Anative path normalization retained scalar semantics\n\z/,
		"audited path normalization runs on $slots slots with boundary input coverage");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use Cwd (); use RootFixture;
		our $expected;
		BEGIN { $expected = Cwd::getcwd() }
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..64) {
					die "cwd changed\n" unless Cwd::getcwd() eq $expected;
					die "fast cwd changed\n" unless Cwd::fastcwd() eq $expected;
					yield;
				}
				$out->send(1);
			};
		}
		die "missing cwd workers\n" if grep { $out->recv != 1 } 1..8;
		eval { Cwd::fastcwd(1) };
		die "cwd alias accepted arguments\n" unless $@ =~ /Usage:/;
		print "native cwd readers retained independent results\n";
	}, 0, qr/\Anative cwd readers retained independent results\n\z/,
		"audited cwd readers run on $slots slots and retain alias argument validation");
}

{
	local $ENV{WUMPPROCS} = 4;
	WumpTest::check_program(q{
		use Wump; use Cwd (); use File::Temp ();
		our $original;
		BEGIN {
			$original = Cwd::getcwd();
			my $gone = File::Temp::tempdir(TMPDIR => 1);
			chdir $gone or die "chdir: $!";
			rmdir $gone or die "rmdir: $!";
		}
		die "deleted cwd did not fail\n" if defined Cwd::getcwd();
		# Only the main act is running; restore the process directory before
		# starting any workers or loading more files.
		chdir $original or die "restore cwd: $!";
		die "cwd did not recover\n" unless Cwd::getcwd() eq $original;
		eval { Cwd::abs_path('.') };
		die "unaudited cwd helper admitted: $@" unless $@ =~ /XS function has not declared parallel safety: Cwd::abs_path/;
		print "cwd failure recovered and other native path helpers stayed gated\n";
	}, 0, qr/\Acwd failure recovered and other native path helpers stayed gated\n\z/,
		'cwd readers preserve failure/recovery behavior without admitting unrelated helpers');
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump;
		use Time::HiRes ();
		use RootFixture;
		BEGIN { Time::HiRes::CLOCK_MONOTONIC() }
		my $clock = Time::HiRes::CLOCK_MONOTONIC();
		my $slots = Wump::execution_slots();
		die "wrong execution slots\n" unless $slots == $ENV{WUMPPROCS};
		eval { Wump::execution_slots(1) };
		die "slot query accepted arguments: $@" unless $@ =~ /no arguments/;
		# No workers have started yet. Change the process setting explicitly;
		# localizing ENV elements inside an act is outside the current bridge.
		my $configured = $ENV{WUMPPROCS};
		$ENV{WUMPPROCS} = 255;
		die "slot report used environment\n" unless Wump::execution_slots() == $slots;
		$ENV{WUMPPROCS} = $configured;
		my $out = chan(4);
		my $group = waitgroup;
		for (1..8) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				die "child slot report changed\n" unless Wump::execution_slots() == $slots;
				for (1..64) {
					my $before = Time::HiRes::clock_gettime($clock);
					my $wall = Time::HiRes::time();
					my ($seconds, $micros) = Time::HiRes::gettimeofday();
					die "invalid wall clock\n" unless $wall > 0 && $seconds > 0
						&& $micros >= 0 && $micros < 1_000_000;
					die "invalid clock resolution\n" unless Time::HiRes::clock_getres($clock) > 0;
					yield;
					die "monotonic clock reversed\n" unless Time::HiRes::clock_gettime($clock) >= $before;
				}
				$out->send(1);
				done $group;
			};
		}
		for (1..8) { die "missing clock workers\n" unless $out->recv == 1 }
		await $group;
		die "invalid clock ID changed behavior\n" unless Time::HiRes::clock_gettime(-12345) == -1;
		print "audited clocks completed on every slot\n";
	}, 0, qr/\Aaudited clocks completed on every slot\n\z/,
		"audited native clocks run with $slots slots and survive migration");
}

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump;
		use Unicode::Normalize qw(NFC NFD NFKC NFKD FCC);
		use RootFixture;
		my @cases = (
			["Cafe\x{301}", "Caf\x{e9}"], ["Caf\x{e9}", "Caf\x{e9}"],
			["A\0e\x{301}", "A\0\x{e9}"], ["\x{1100}\x{1161}", "\x{ac00}"],
			['', ''], [123, '123'],
		);
		my $out = chan(4);
		my $group = waitgroup;
		for (1..8) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					for my $case (@cases) {
						my $expected = $case->[1];
						die "wrong NFC result\n" unless NFC($case->[0]) eq $expected;
						die "wrong NFD round trip\n" unless NFC(NFD($case->[0])) eq $expected;
					}
					die "wrong compatibility composition\n" unless NFKC("\x{fb03}") eq 'ffi';
					die "wrong compatibility decomposition\n" unless NFKD("\x{fb03}") eq 'ffi';
					die "wrong contiguous composition\n" unless FCC("e\x{301}") eq "\x{e9}";
					yield;
				}
				$out->send(1);
				done $group;
			};
		}
		for (1..8) { die "missing Unicode worker\n" unless $out->recv == 1 }
		await $group;
		die "normalization changed shared input\n" unless $cases[0][0] eq "Cafe\x{301}";
		print "shared Unicode inputs normalized without modification\n";
	}, 0, qr/\Ashared Unicode inputs normalized without modification\n\z/,
		"audited Unicode normalization runs on $slots slots with shared inputs");
}

{
	local $ENV{WUMPPROCS} = 4;
	WumpTest::check_program(q{
		use Wump;
		use Time::HiRes ();
		for my $call (\&Time::HiRes::usleep, \&Time::HiRes::alarm) {
			eval { $call->(0) };
			die "unaudited XS admitted: $@" unless $@ =~ /XS function has not declared parallel safety: Time::HiRes::(?:usleep|alarm)/;
		}
		print "blocking calls and process timers remain rejected\n";
	}, 0, qr/\Ablocking calls and process timers remain rejected\n\z/,
		'clock registration does not admit the rest of Time::HiRes and identifies rejected entries');
	WumpTest::check_program(q{
		use Wump;
		use Unicode::Normalize qw(NFC compose);
		use RootFixture;
		our $bad;
		BEGIN { $bad = RootFixture::malformed_utf8() }
		package NormalizeTie {
			sub TIESCALAR { bless {}, shift }
			sub FETCH { die "unexpected normalization FETCH\n" }
		}
		tie my $magical, 'NormalizeTie';
		eval { NFC($magical) };
		die "magical input admitted: $@" unless $@ =~ /requires a plain scalar/;
		eval { NFC($bad) };
		die "malformed input admitted: $@" unless $@ =~ /requires well-formed UTF-8/;
		eval { NFC([]) };
		die "reference input admitted: $@" unless $@ =~ /requires a plain scalar/;
		eval { compose('text') };
		die "unaudited normalizer admitted: $@" unless $@ =~ /XS function has not declared parallel safety: Unicode::Normalize::compose/;
		die "normalizer failed after rejection\n" unless NFC("e\x{301}") eq "\x{e9}";
		print "invalid normalization inputs and unaudited entries rejected\n";
	}, 0, qr/\Ainvalid normalization inputs and unaudited entries rejected\n\z/,
		'normalization rejects unsupported inputs before allocating native buffers and recovers');
}

done_testing;
