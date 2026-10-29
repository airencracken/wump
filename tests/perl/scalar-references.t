use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'weaken';
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

# The source RV can remain alive while losing its original referent. Neither
# keeping the source head nor snapshotting an operand after RHS evaluation
# protects the scalar head which rv2sv has already put on the act stack.
for my $case (
	['lexical scalar', 'my $root = do { my $value = 40; \\$value };', '\\$root', '$root', '$$root'],
	['package scalar', 'our $root = do { my $value = 40; \\$value };', '\\$root', '$root', '$$root'],
	['array element', 'my @roots = (do { my $value = 40; \\$value });', '\\@roots', '$roots[0]', '${$roots[0]}'],
	['hash element', 'my %roots = (key => do { my $value = 40; \\$value });', '\\%roots', '$roots{key}', '${$roots{key}}'],
	['nested reference', 'my $root = do { my $value = 40; my $inner = \\$value; \\$inner };', '\\$root', '$root', '$$$root'],
) {
	my ($name, $setup, $publish, $root, $expression) = @$case;
	for my $mode ('operand', 'argument', 'compound', 'lvalue return') {
		my $calculation = $mode eq 'operand' ? "$expression + \$delay->()"
			: $mode eq 'argument' ? "\$consume->($expression, \$delay->())"
			: $mode eq 'compound' ? "($expression += \$delay->())"
			: '$consume->($slot->(), $delay->())';
		WumpTest::check_program(qq{
			use strict; use warnings; use Wump; use RootFixture;
			use Scalar::Util qw(weaken refaddr);
			$setup
			RootFixture::scalar_publish($publish);
			my \$weak = \\$expression; weaken(\$weak);
			my \$go = chan; my \$group = waitgroup; add \$group;
			act { \$go->recv; $root = undef; done \$group };
			my \$delay = sub {
				\$go->send(1); await \$group;
				die "extracted scalar was freed\\n" unless defined \$weak;
				2
			};
			my \$consume = sub {
				die "scalar alias changed\\n" unless refaddr(\\\$_[0]) == refaddr(\$weak);
				\$_[0] += \$_[1]; \$_[0]
			};
			my \$slot = sub :lvalue { $expression };
			my \$answer = $calculation;
			die "wrong scalar result: \$answer\\n" unless \$answer == 42;
			die "extracted scalar leaked\\n" if defined \$weak;
			print "scalar referent retained and released\\n";
		}, 0, qr/\Ascalar referent retained and released\n\z/, "$name $mode survives source replacement");
	}
}

my $root = do { my $value = 40; \$value };
RootFixture::scalar_publish(\$root);
my ($ready, $release) = (chan, chan);
my $group = waitgroup;
add $group;
act {
	RootFixture::memory_guard(\$root, sub { $ready->send(1); $release->recv });
	done $group;
};
$ready->recv;
eval { my $unused = $$root };
like($@, qr/read overlaps mutation/, 'scalar dereference rejects a foreign source writer before reading the RV');
$release->send(1); await $group;
RootFixture::memory_guard(\$root, sub { is($$root, 40, 'scalar extraction works inside its own source writer') });

{
	my $source = do { my $value = 40; \$value };
	my $weak = $source; weaken($weak);
	RootFixture::scalar_publish(\$source);
	add $group;
	act {
		RootFixture::memory_guard($source, sub { $ready->send(1); $release->recv });
		done $group;
	};
	$ready->recv;
	eval { my $unused = $$source };
	like($@, qr/read overlaps mutation/, 'scalar classification rejects a foreign referent writer');
	$source = undef;
	$release->send(1); await $group;
	ok(!defined $weak, 'failed classification releases the partial scalar capture');
}

for my $exit ('exception', 'abandonment') {
	my $program = $exit eq 'exception' ? q{
		my $delay = sub { undef $source; die "RHS failed\n" };
		eval { $consume->($$source, $delay->()) };
		die "exception changed\n" unless $@ eq "RHS failed\n";
		die "scalar capture leaked\n" if defined $weak;
		print "scalar capture unwound\n";
	} : q{
		my $entered = chan; my $park = chan;
		act { $consume->($$source, do { $entered->send(1); $park->recv; 0 }) };
		$entered->recv; undef $source;
		die "parked scalar was freed\n" unless defined $weak;
		print "scalar capture parked\n";
	};
	WumpTest::check_program(q{
		use Wump; use RootFixture; use Scalar::Util 'weaken';
		my $source = do { my $value = 40; \$value };
		my $weak = $source; weaken($weak);
		RootFixture::scalar_publish(\$source);
		my $consume = sub { $_[0] += 2 };
	} . $program, 0, qr/\Ascalar capture (?:unwound|parked)\n\z/,
		"$exit releases scalar captures through task temporary cleanup");
}

# Rejected type and localization paths must leave no hidden strong pin while
# Perl's diagnostic callback yields, destroys the source and throws.
for my $case (
	['wrong type', 'my $source = [40];', 'my $unused = $$source'],
	['local reference', 'my $source = do { my $value = 40; \\$value };', 'local $$source = 42'],
) {
	my ($name, $setup, $operation) = @$case;
	WumpTest::check_program(qq{
		use Wump; use RootFixture; use Scalar::Util 'weaken';
		$setup
		RootFixture::scalar_publish(\\\$source);
		my \$weak = \$source; weaken(\$weak);
		local \$SIG{__DIE__} = sub {
			undef \$source; Wump::yield();
			die defined(\$weak) ? "diagnostic retained target\\n" : "diagnostic released target\\n";
		};
		eval { $operation };
		die "native diagnostic path changed: \$@" unless \$@ eq "diagnostic released target\\n";
		print "native diagnostic target released\\n";
	}, 0, qr/\Anative diagnostic target released\n\z/, "$name capture rejection releases its target before diagnostics");
}

{
	package ScalarReferenceTie;
	sub TIESCALAR { bless {value => $_[1], gets => 0, sets => 0}, $_[0] }
	sub FETCH { $_[0]{gets}++; Wump::yield(); $_[0]{value} }
	sub STORE { $_[0]{sets}++; $_[0]{value} = $_[1] }
	package ScalarReferenceOverload;
	use overload '${}' => sub { $_[0]{gets}++; Wump::yield(); $_[0]{value} }, fallback => 1;
}
my $magic = tie my $tied_source, 'ScalarReferenceTie', $root;
RootFixture::scalar_publish(\$tied_source);
is($$tied_source, 40, 'tied source retains its yielding FETCH callback');
is($magic->{gets}, 1, 'scalar source classification adds no FETCH');
my $object = bless {value => $root, gets => 0}, 'ScalarReferenceOverload';
RootFixture::scalar_publish(\$object);
is($$object, 40, 'scalar dereference retains yielding overload');
is($object->{gets}, 1, 'scalar source classification adds no overload call');

my $target_magic = tie my $target, 'ScalarReferenceTie', 40;
my $target_ref = \$target;
RootFixture::scalar_publish(\$target_ref);
$$target_ref += 2;
is_deeply([@$target_magic{qw(value gets sets)}], [42, 1, 1], 'captured tied scalar retains one FETCH, STORE and its writable alias');
my $substring = \substr($$root, 0, 1);
RootFixture::scalar_publish(\$substring);
$$substring = '5';
is($$root, 50, 'captured native lvalue delegate updates its original target');

for my $kind ('scalar', 'array', 'hash') {
	my $source = do { my $value; \$value };
	RootFixture::scalar_publish(\$source);
	if ($kind eq 'array') { $$source->[0] = 42 }
	elsif ($kind eq 'hash') { $$source->{key} = 42 }
	else { $$$source = 42 }
	ok(Wump::is_shared($$source), "scalar extraction preserves $kind autovivification and referent publication");
}

{
	no strict 'refs';
	our $symbolic_value = 42;
	my $symbol = __PACKAGE__ . '::symbolic_value';
	is($$symbol, 42, 'symbolic scalar reference retains native lookup');
	local $$symbol = 17;
	is($symbolic_value, 17, 'symbolic scalar localization retains its act-local binding');
}
my $wrong = [];
RootFixture::scalar_publish(\$wrong);
eval { my $unused = $$wrong };
like($@, qr/Not a SCALAR reference/, 'wrong scalar referent retains its native diagnostic');
my $weak = $root; weaken($weak);
RootFixture::scalar_publish(\$weak);
is($$weak, 50, 'weak scalar reference retains native dereference behavior');

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my $owner = do { my $value = 40; \$value };
	my $source = $owner; weaken($source);
	RootFixture::scalar_publish(\$source);
	my $consume = sub { $_[0] };
	my $delay = sub {
		undef $owner;
		die defined($source) ? "weak source strengthened\n" : "weak source released\n";
	};
	eval { $consume->($$source, $delay->()) };
	die "weak semantics changed: $@" unless $@ eq "weak source released\n";
	print "weak source stays weak\n";
}, 0, qr/\Aweak source stays weak\n\z/, 'rejected weak scalar source gains no hidden referent pin');

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	{ package ScalarReferenceObject; sub DESTROY { $main::destroyed++ } }
	our $destroyed = 0;
	my $source = bless do { my $value = 40; \$value }, 'ScalarReferenceObject';
	my $weak = $source; weaken($weak);
	RootFixture::scalar_publish(\$source);
	my $consume = sub { $_[0] };
	my $delay = sub {
		undef $source;
		die !defined($weak) && $destroyed == 1 ? "object released\n" : "object retained\n";
	};
	eval { $consume->($$source, $delay->()) };
	die "object timing changed: $@" unless $@ eq "object released\n";
	print "object timing retained\n";
}, 0, qr/\Aobject timing retained\n\z/, 'rejected blessed scalar target retains native destructor timing');

done_testing;
