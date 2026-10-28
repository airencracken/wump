use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(dualvar refaddr);
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

my $generation = RootFixture::namespace_generation();
my $private_globs;
my $glob_group = waitgroup;
add $glob_group;
act { $private_globs = RootFixture::task_globs(); done $glob_group };
await $glob_group;
is_deeply($private_globs, [[1, 1, '_'], [1, 1, '@'], [1, 1, "\022"]],
	'private task globs retain their names without namespace links or prototype CVs');
is(RootFixture::namespace_generation(), $generation, 'starting and retiring task globs leaves method-cache generation unchanged');
my $default_result = chan;
add $glob_group;
act {
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	$_ = undef;
	RootFixture::scalar_publish(\$_);
	my $result = $_ + 2;
	$default_result->send([$result, $warnings[0]]);
	done $glob_group;
};
my $default = $default_result->recv;
await $glob_group;
is($default->[0], 2, 'private default scalar retains arithmetic semantics');
like($default->[1], qr/\$_/, 'private default scalar retains its diagnostic name');

my @binary = (
	['add', sub { $_[0] + $_[1] }], ['subtract', sub { $_[0] - $_[1] }],
	['multiply', sub { $_[0] * $_[1] }], ['divide', sub { $_[0] / $_[1] }],
	['modulo', sub { $_[0] % $_[1] }], ['power', sub { $_[0] ** $_[1] }],
	['left shift', sub { $_[0] << $_[1] }], ['right shift', sub { $_[0] >> $_[1] }],
	['numeric and', sub { $_[0] & $_[1] }], ['numeric or', sub { $_[0] | $_[1] }],
	['numeric xor', sub { $_[0] ^ $_[1] }],
	['string and', sub { $_[0] &. $_[1] }], ['string or', sub { $_[0] |. $_[1] }],
	['string xor', sub { $_[0] ^. $_[1] }],
	['less', sub { $_[0] < $_[1] }], ['greater', sub { $_[0] > $_[1] }],
	['less equal', sub { $_[0] <= $_[1] }], ['greater equal', sub { $_[0] >= $_[1] }],
	['equal', sub { $_[0] == $_[1] }], ['unequal', sub { $_[0] != $_[1] }],
	['compare', sub { $_[0] <=> $_[1] }],
	['string less', sub { $_[0] lt $_[1] }], ['string greater', sub { $_[0] gt $_[1] }],
	['string less equal', sub { $_[0] le $_[1] }], ['string greater equal', sub { $_[0] ge $_[1] }],
	['string equal', sub { $_[0] eq $_[1] }], ['string unequal', sub { $_[0] ne $_[1] }],
	['string compare', sub { $_[0] cmp $_[1] }],
);
{
	use integer;
	push @binary,
		['integer add', sub { $_[0] + $_[1] }], ['integer subtract', sub { $_[0] - $_[1] }],
		['integer multiply', sub { $_[0] * $_[1] }], ['integer divide', sub { $_[0] / $_[1] }],
		['integer modulo', sub { $_[0] % $_[1] }],
		['integer less', sub { $_[0] < $_[1] }], ['integer greater', sub { $_[0] > $_[1] }],
		['integer less equal', sub { $_[0] <= $_[1] }], ['integer greater equal', sub { $_[0] >= $_[1] }],
		['integer equal', sub { $_[0] == $_[1] }], ['integer unequal', sub { $_[0] != $_[1] }],
		['integer compare', sub { $_[0] <=> $_[1] }];
}

my $shared = 42;
RootFixture::scalar_publish(\$shared);
my ($ready, $release) = (chan, chan);
my $group = waitgroup;
add $group;
act {
	RootFixture::memory_guard(\$shared, sub { $ready->send(1); $release->recv });
	done $group;
};
$ready->recv;
for my $spec (@binary) {
	for my $side (0, 1) {
		eval { $side ? $spec->[1]->(2, $shared) : $spec->[1]->($shared, 2) };
		like($@, qr/read overlaps mutation/, "$spec->[0] checks source $side before fast paths");
	}
}
$release->send(1);
await $group;

for my $spec (@binary) {
	my $expected = $spec->[1]->(42, 2);
	is($spec->[1]->($shared, 2), $expected, "$spec->[0] retains ordinary results");
}
my @compound = (
	sub { ${$_[0]} += $_[1] }, sub { ${$_[0]} -= $_[1] },
	sub { ${$_[0]} *= $_[1] }, sub { ${$_[0]} /= $_[1] },
);
for my $operation (@compound) {
	my ($private, $published) = (42, 42);
	RootFixture::scalar_publish(\$published);
	$operation->(\$private, $private);
	$operation->(\$published, $published);
	is($published, $private, 'compound assignment preserves destination/source alias semantics');
}

my $dual = dualvar(42, 'forty-two');
RootFixture::scalar_publish(\$dual);
is($dual + 2, 44, 'numeric reads preserve dual values');
is($dual cmp 'forty-two', 0, 'string reads preserve dual values');
is("$dual", 'forty-two', 'reads leave the original string cache intact');
is($shared - $shared, 0, 'aliased inputs use a consistent operand view');

for my $value ('42', 42, 42.5, ~0, true, false, "a\0\x{100}") {
	my $private = $value;
	my $expected_string = $private cmp '42';
	my $expected_number = $private eq "a\0\x{100}" ? undef : $private + 2;
	RootFixture::scalar_publish(\$value);
	my $before = RootFixture::scalar_state(\$value);
	my $string_result = $value cmp '42';
	my $numeric_result = $value eq "a\0\x{100}" ? undef : $value + 2;
	is($string_result, $expected_string, 'published string comparison matches the private control');
	is($numeric_result, $expected_number, 'published arithmetic matches the private control at scalar boundaries');
	is_deeply(RootFixture::scalar_state(\$value), $before, 'numeric/string operands retain source flags, bodies, and buffers');
}

our $warning_source;
RootFixture::scalar_publish(\$warning_source);
my (@warnings, $answer, $nested, $frame_restored);
{
	local $SIG{__WARN__} = sub {
		push @warnings, $_[0];
		yield;
		$warning_source = 20;
		$nested = $warning_source + 2;
		$frame_restored = RootFixture::read_frame_active();
	};
	$answer = $warning_source + 2;
}
is($answer, 2, 'warning callback can change the source while an opcode retains its captured value');
is($warning_source, 20, 'operand snapshots hold no reader exclusion across callbacks');
is($nested, 22, 'a warning callback can execute a nested guarded opcode');
ok($frame_restored, 'nested opcode completion restores the enclosing diagnostic frame');
like($warnings[0], qr/\$warning_source/, 'undefined-value diagnostic identifies the original variable');
ok(!RootFixture::read_frame_active(), 'normal opcode completion clears source diagnostic frames');

our $throwing_source;
RootFixture::scalar_publish(\$throwing_source);
{
	local $SIG{__WARN__} = sub { yield; die "operand warning exception\n" };
	eval { my $unused = $throwing_source + 2 };
	like($@, qr/operand warning exception/, 'warning exception propagates through operand preparation');
}
ok(!RootFixture::read_frame_active(), 'exception unwind clears operand frames');
$throwing_source = 42;
is($throwing_source + 2, 44, 'source remains usable after an exception');

{
	package OperandTied;
	sub TIESCALAR { bless {value => 40, fetches => 0}, shift }
	sub FETCH { $_[0]{fetches}++; Wump::yield(); return $_[0]{value} }
	sub STORE { $_[0]{value} = $_[1] }
}
my $tie = tie my $tied, 'OperandTied';
is($tied + 2, 42, 'tied input retains its FETCH path');
is($tie->{fetches}, 1, 'classification does not add a tied FETCH');
{
	package OperandOverload;
	use overload '+' => sub {
		my ($self, $other, $swapped) = @_;
		$self->{seen} = Scalar::Util::refaddr(\$_[1]);
		Wump::yield();
		return $other + 1;
	}, fallback => 1;
}
my $object = bless {}, 'OperandOverload';
my $alias = 41;
RootFixture::scalar_publish(\$alias);
is($object + $alias, 42, 'mixed object input retains overload dispatch');
is($object->{seen}, refaddr(\$alias), 'overload receives the original scalar alias');
is($alias + $object, 42, 'reversed overload dispatch retains its arguments');
is($object->{seen}, refaddr(\$alias), 'reversed overload receives the original scalar alias');

WumpTest::check_program(q{
	use Wump;
	use RootFixture;
	our $source;
	RootFixture::scalar_publish(\$source);
	my $entered = chan;
	my $park = chan;
	act {
		local $SIG{__WARN__} = sub { $entered->send(1); $park->recv };
		my $unused = $source + 2;
	};
	$entered->recv;
	print "operand callback parked\n";
}, 0, qr/\Aoperand callback parked\n\z/,
	'abandoned warning callbacks unwind their operand frames and source roots');

done_testing;
