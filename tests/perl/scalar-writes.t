use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'dualvar';
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

my @operations = (
	['assign', sub { ${$_[0]} = 17 }],
	['preinc', sub { ++${$_[0]} }], ['predec', sub { --${$_[0]} }],
	['postinc', sub { ${$_[0]}++ }], ['postdec', sub { ${$_[0]}-- }],
	['add', sub { ${$_[0]} += 2 }], ['subtract', sub { ${$_[0]} -= 2 }],
	['multiply', sub { ${$_[0]} *= 2 }], ['divide', sub { ${$_[0]} /= 2 }],
	['modulo', sub { ${$_[0]} %= 3 }], ['power', sub { ${$_[0]} **= 2 }],
	['left shift', sub { ${$_[0]} <<= 1 }], ['right shift', sub { ${$_[0]} >>= 1 }],
	['numeric and', sub { ${$_[0]} &= 7 }], ['numeric or', sub { ${$_[0]} |= 7 }],
	['numeric xor', sub { ${$_[0]} ^= 7 }],
	['string and', sub { ${$_[0]} &.= 'zz' }],
	['string or', sub { ${$_[0]} |.= 'zz' }],
	['string xor', sub { ${$_[0]} ^.= 'zz' }],
	['concat', sub { ${$_[0]} .= 'x' }],
	['multiconcat', sub { my ($a, $b) = ('x', 'y'); ${$_[0]} .= "<$a:$b>" }],
	['multiconcat assign', sub { my ($a, $b) = ('x', 'y'); ${$_[0]} = "<$a:$b>" }],
	['chop', sub { chop ${$_[0]} }], ['chomp', sub { chomp ${$_[0]} }],
	['substring', sub { substr(${$_[0]}, 0, 1) = 'x' }],
	['vector', sub { vec(${$_[0]}, 0, 8) = 65 }],
);
{
	use integer;
	push @operations,
		['integer preinc', sub { ++${$_[0]} }], ['integer postinc', sub { ${$_[0]}++ }],
		['integer predec', sub { --${$_[0]} }], ['integer postdec', sub { ${$_[0]}-- }],
		['integer add', sub { ${$_[0]} += 2 }], ['integer subtract', sub { ${$_[0]} -= 2 }],
		['integer multiply', sub { ${$_[0]} *= 2 }], ['integer divide', sub { ${$_[0]} /= 2 }],
		['integer modulo', sub { ${$_[0]} %= 3 }];
}

my $value = '42';
RootFixture::scalar_publish(\$value);
my ($ready, $release) = (chan, chan);
my $group = waitgroup;
add $group;
act {
	RootFixture::memory_guard(\$value, sub { $ready->send(1); $release->recv });
	done $group;
};
$ready->recv;
for my $spec (@operations) {
	my ($name, $operation) = @$spec;
	eval { $operation->(\$value) };
	like($@, qr/(?:concurrent mutation|read overlaps mutation)/, "$name rejects another act's active writer");
}
for my $kind (0..11) {
	eval { RootFixture::scalar_write(\$value, $kind, 'replacement') };
	like($@, qr/concurrent mutation/, "C mutation $kind rejects another act's writer");
}
$release->send(1);
await $group;
is($value, '42', 'rejected writes preserve the original value');

my $lexical_target = 'old:';
my ($lexical_left, $lexical_right) = ('A', 'B');
my @lexical_operations = (
	['lexical concat assignment', sub { $lexical_target = "<$lexical_left:$lexical_right>" }, '<A:B>'],
	['lexical concat append', sub { $lexical_target .= "<$lexical_left:$lexical_right>" }, 'old:<A:B>'],
	['lexical alias concat', sub { $lexical_target = $lexical_left . $lexical_target }, 'Aold:'],
	['lexical arithmetic assignment', sub { my ($a, $b) = (40, 2); $lexical_target = $a + $b }, 42],
);
RootFixture::scalar_publish(\$lexical_target);
RootFixture::scalar_publish($_->[1]) for @lexical_operations;
my ($lexical_ready, $lexical_release) = (chan, chan);
my $lexical_group = waitgroup;
add $lexical_group;
act {
	RootFixture::memory_guard(\$lexical_target, sub { $lexical_ready->send(1); $lexical_release->recv });
	done $lexical_group;
};
$lexical_ready->recv;
for my $spec (@lexical_operations) {
	eval { $spec->[1]->() };
	like($@, qr/concurrent mutation/, "$spec->[0] guards its pad destination");
}
$lexical_release->send(1);
await $lexical_group;
for my $spec (@lexical_operations) {
	RootFixture::memory_replace(\$lexical_target, 'old:');
	my $old = RootFixture::memory_borrow(\$lexical_target, 0, $spec->[1]);
	is($old, 'old:', "$spec->[0] retains its old pad buffer");
	is($lexical_target, $spec->[2], "$spec->[0] preserves pad assignment semantics");
}

for my $spec (@operations) {
	my ($name, $operation) = @$spec;
	my $control = "42\n";
	my $subject = "42\n";
	RootFixture::scalar_publish(\$subject);
	RootFixture::memory_replace(\$subject, "42\n");
	my $expected = $operation->(\$control);
	my $returned;
	my $old = RootFixture::memory_borrow(\$subject, 0, sub { $returned = $operation->(\$subject) });
	is($old, "42\n", "$name preserves borrowed original bytes");
	is($subject, $control, "$name preserves Perl value semantics");
	is($returned, $expected, "$name preserves its expression result");
}

for my $initial (42, 42.0, 42.25, 9223372036854775807, 18446744073709551615, 'Az', 'zz', dualvar(7, 'seven')) {
	for my $kind (0..3) {
		my ($control, $subject) = ($initial, $initial);
		RootFixture::scalar_publish(\$subject);
		RootFixture::scalar_write(\$control, $kind);
		RootFixture::scalar_write(\$subject, $kind);
		is($subject, $control, "C numeric mutation $kind matches a private scalar at representation boundaries");
	}
}

for my $spec (
	[4, "\xe9", 0], [5, "\xc3\xa9", 0], [6, "\xe9", 1], [11, "\x{20ac}", 1],
	[7, 'original', 0], [8, '42', 0], [9, '42', 0], [10, '42.5', 0],
) {
	my ($kind, $initial, $upgrade) = @$spec;
	my ($control, $subject) = ($initial, $initial);
	utf8::upgrade($control) if $upgrade;
	utf8::upgrade($subject) if $upgrade;
	RootFixture::scalar_publish(\$subject);
	my $original = $subject;
	my $expected = RootFixture::scalar_write(\$control, $kind, 'replacement');
	my $returned;
	my $old = RootFixture::memory_borrow(\$subject, $upgrade ? 4 : 0, sub {
		$returned = RootFixture::scalar_write(\$subject, $kind, 'replacement');
	});
	is($old, $original, "C mutation $kind preserves borrowed bytes and encoding");
	is($subject, $control, "C mutation $kind preserves value semantics");
	is(utf8::is_utf8($subject), utf8::is_utf8($control), "C mutation $kind preserves encoding flags");
	is($returned, $expected, "C mutation $kind preserves its return value");
}

RootFixture::memory_replace(\$value, '42');
eval { $value /= 0 };
like($@, qr/Illegal division by zero/, 'opcode exceptions retain Perl diagnostics');
$value += 1;
is($value, 43, 'an opcode exception releases the writer claim');

my @array = ('first', 'second');
my %hash = (key => "third\n");
RootFixture::scalar_publish(\@array);
RootFixture::scalar_publish(\%hash);
is(chop(@array), 'd', 'recursive array chop returns the last removed character');
is_deeply(\@array, ['firs', 'secon'], 'recursive chop mutates published child values');
is(chomp(%hash), 1, 'recursive hash chomp returns its character count');
is($hash{key}, 'third', 'recursive chomp mutates the live hash value');

for my $kind ('substring', 'vector') {
	my $subject = 'abcdef';
	RootFixture::scalar_publish(\$subject);
	my $alias = $kind eq 'substring' ? \substr($subject, 1, 2) : \vec($subject, 0, 8);
	my ($ready, $release) = (chan, chan);
	my $group = waitgroup;
	add $group;
	act {
		RootFixture::memory_guard(\$subject, sub { $ready->send(1); $release->recv });
		done $group;
	};
	$ready->recv;
	eval { $$alias = $kind eq 'substring' ? 'XY' : 65 };
	like($@, qr/concurrent mutation/, "$kind lvalue guards its original referent after alias creation");
	$release->send(1);
	await $group;
	is($subject, 'abcdef', 'a rejected proxy write preserves its referent');
}

my $store_hook;
{
	package OpcodeTie;
	sub TIESCALAR { bless {value => 42}, $_[0] }
	sub FETCH { $_[0]{value} }
	sub STORE { $store_hook->() if $store_hook; $_[0]{value} = $_[1] }
}
for my $guarded (0, 1) {
	tie my $subject, 'OpcodeTie';
	RootFixture::scalar_publish(\$subject);
	my ($begin, $finished) = (chan, chan);
	my $group = waitgroup;
	add $group;
	act {
		$begin->recv;
		eval { RootFixture::memory_replace(\$subject, '99') };
		$finished->send($@);
		done $group;
	};
	my $error;
	$store_hook = sub { $begin->send(1); $error = $finished->recv };
	if ($guarded) { ++$subject }
	else { RootFixture::unguarded_increment(\$subject) }
	$store_hook = undef;
	await $group;
	if ($guarded) { like($error, qr/concurrent mutation/, 'the opcode claim spans a yielding STORE callback') }
	else { is($error, '', 'the original opcode body alone releases its C API claim before STORE') }
}

tie my $throwing, 'OpcodeTie';
RootFixture::scalar_publish(\$throwing);
$store_hook = sub { die "opcode STORE failed\n" };
eval { ++$throwing };
like($@, qr/opcode STORE failed/, 'throwing opcode callbacks preserve their exception');
$store_hook = undef;
$throwing = 19;
is($throwing, 19, 'a throwing STORE releases both opcode and nested mutation claims');

WumpTest::check_program(q{
	use Wump; use RootFixture;
	my ($ready, $park) = (chan, chan);
	{
		package AbandonedOpcodeTie;
		sub TIESCALAR { bless {}, $_[0] }
		sub FETCH { 42 }
		sub STORE { $ready->send(1); $park->recv }
	}
	tie my $value, 'AbandonedOpcodeTie';
	act { ++$value };
	$ready->recv;
	print "opcode parked\n";
}, 0, qr/\Aopcode parked\n\z/, 'abandoned opcode callbacks release their mutation claims');

my $stats = RootFixture::memory_stats();
is_deeply([@$stats[0, 1]], [0, 0], 'scalar mutations leave no lifetime pins or retired storage');
done_testing;
