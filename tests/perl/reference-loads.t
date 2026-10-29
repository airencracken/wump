use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

# Watch the referent, not the source RV head. Reassigning that same head can
# destroy the previously extracted container while its index/key is evaluated.
for my $case (
	['generic array', 'my $root = [40];', '\\$root', '$root', '$root->[$delayed->()]', '[99]', 0],
	['generic hash', 'my $root = {key => 40};', '\\$root', '$root', '$root->{$delayed->()}', '{key => 99}', 'key'],
	['optimized array', 'my $root = [40];', '\\$root', '$root', '$root->[$index]', '[99]', 0],
	['optimized hash', 'my $root = {key => 40};', '\\$root', '$root', '$root->{$index}', '{key => 99}', 'key'],
	['package array', 'our $root = [40];', '\\$root', '$root', '$root->[$index]', '[99]', 0],
	['package hash', 'our $root = {key => 40};', '\\$root', '$root', '$root->{$index}', '{key => 99}', 'key'],
	['nested array', 'my @roots = ([40]);', '\\@roots', '$roots[0]', '$roots[0][$index]', '[99]', 0],
	['nested hash', 'my %roots = (child => {key => 40});', '\\%roots', '$roots{child}', '$roots{child}{$index}', '{key => 99}', 'key'],
) {
	my ($name, $setup, $publish, $root, $expression, $replacement, $index) = @$case;
	for my $clear (0, 1) {
		my $change = $clear ? "$root = undef" : "$root = $replacement";
		my $code = qq{
			use strict; use warnings; use Wump; use RootFixture;
			use Scalar::Util 'weaken';
			$setup
			RootFixture::scalar_publish($publish);
			my \$weak = $root; weaken(\$weak);
			my \$go = chan; my \$finished = waitgroup; add \$finished;
			act { \$go->recv; $change; done \$finished };
			my \$delayed = sub {
				\$go->send(1); await \$finished;
				die "extracted container was freed\\n" unless defined \$weak;
				'$index'
			};
			{
				package ReferenceIndex;
				sub TIESCALAR { bless [\$_[1]], \$_[0] }
				sub FETCH { \$_[0][0]->() }
			}
			tie my \$index, 'ReferenceIndex', \$delayed;
			my \$answer = $expression + 2;
			die "wrong captured result: \$answer\\n" unless \$answer == 42;
			die "captured container leaked\\n" if defined \$weak;
			print "referent retained and released\\n";
		};
		WumpTest::check_program($code, 0, qr/\Areferent retained and released\n\z/,
			"$name extraction survives " . ($clear ? 'undefining its source' : 'source replacement'));
	}
}

my $array = [40];
my $hash = {key => 40};
RootFixture::scalar_publish(\$array);
RootFixture::scalar_publish(\$hash);
my ($ready, $release) = (chan, chan);
my $group = waitgroup;
for my $case (
	['array', \$array, sub { $array->[0] + 2 }],
	['hash', \$hash, sub { $hash->{key} + 2 }],
) {
	add $group;
	act {
		RootFixture::memory_guard($case->[1], sub { $ready->send(1); $release->recv });
		done $group;
	};
	$ready->recv;
	eval { $case->[2]->() };
	like($@, qr/read overlaps mutation/, "$case->[0] extraction rejects a foreign RV writer");
	$release->send(1); await $group;
}
RootFixture::memory_guard(\$array, sub { is($array->[0] + 2, 42, 'array extraction inside its own source writer works') });
RootFixture::memory_guard(\$hash, sub { is($hash->{key} + 2, 42, 'hash extraction inside its own source writer works') });
my $weak = $array;
weaken($weak);
is($weak->[0], 40, 'weak reference retains its native dereference behavior');
WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my $owner = [40]; my $weak = $owner; weaken($weak);
	RootFixture::scalar_publish(\$weak);
	my $index = sub {
		undef $owner;
		die defined($weak) ? "weak reference strengthened\n" : "weak reference released\n";
	};
	eval { my $unused = $weak->[$index->()] };
	die "weak semantics changed: $@" unless $@ eq "weak reference released\n";
	print "weak semantics retained\n";
}, 0, qr/\Aweak semantics retained\n\z/, 'unsupported weak source gains no hidden strong reference');
WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	{ package ReferenceBlessed; sub DESTROY { $main::destroyed++ } }
	our $destroyed = 0;
	my $root = bless [40], 'ReferenceBlessed';
	my $weak = $root; weaken($weak);
	RootFixture::scalar_publish(\$root);
	my $index = sub {
		undef $root;
		die !defined($weak) && $destroyed == 1 ? "object released\n" : "object retained\n";
	};
	eval { my $unused = $root->[$index->()] };
	die "destructor timing changed: $@" unless $@ eq "object released\n";
	print "object timing retained\n";
}, 0, qr/\Aobject timing retained\n\z/, 'unsupported blessed source gains no hidden referent pin');

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my $root = [40]; my $weak = $root; weaken($weak);
	RootFixture::scalar_publish(\$root);
	my $index = sub { undef $root; die "index exception\n" };
	eval { my $unused = $root->[$index->()] };
	die "exception changed\n" unless $@ eq "index exception\n";
	die "exception leaked referent\n" if defined $weak;
	print "exception released referent\n";
}, 0, qr/\Aexception released referent\n\z/, 'index exception releases the captured referent');
WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my $root = {key => 40}; my $weak = $root; weaken($weak);
	RootFixture::scalar_publish(\$root);
	my $entered = chan; my $park = chan;
	my $key = sub { $entered->send(1); $park->recv; 'key' };
	act { my $unused = $root->{$key->()} };
	$entered->recv; undef $root;
	die "parked referent was freed\n" unless defined $weak;
	print "referent parked\n";
}, 0, qr/\Areferent parked\n\z/, 'abandoned key evaluation releases its referent during teardown');

{
	my $root = [40]; my $weak = $root; weaken($weak);
	RootFixture::scalar_publish(\$root);
	add $group;
	act {
		RootFixture::memory_guard($root, sub { $ready->send(1); $release->recv });
		done $group;
	};
	$ready->recv;
	eval { my $unused = $root->[0] };
	like($@, qr/read overlaps mutation/, 'referent classification rejects a foreign target writer');
	$root = [42];
	is($root->[0], 42, 'failed target classification leaves the source writable');
	$release->send(1); await $group;
	ok(!defined $weak, 'failed target capture releases its partial referent pin');
}
eval { my $unused = $array->{key} };
like($@, qr/Not a HASH reference/, 'wrong referent type retains its diagnostic');
my $missing;
$missing->[0] = 42;
is($missing->[0], 42, 'undefined source retains autovivification');
{
	package ReferenceTied;
	sub TIESCALAR { bless {value => $_[1], gets => 0}, $_[0] }
	sub FETCH { $_[0]{gets}++; Wump::yield(); $_[0]{value} }
	package ReferenceOverload;
	use overload '@{}' => sub { $_[0]{gets}++; Wump::yield(); $_[0]{value} }, fallback => 1;
}
my $tied = tie my $magic, 'ReferenceTied', [40];
RootFixture::scalar_publish(\$magic);
is($magic->[0] + 2, 42, 'tied source retains its FETCH callback');
is($tied->{gets}, 1, 'classification adds no FETCH');
my $object = bless {value => [40], gets => 0}, 'ReferenceOverload';
RootFixture::scalar_publish(\$object);
is($object->[0] + 2, 42, 'object retains dereference overload');
is($object->{gets}, 1, 'classification adds no overload call');

done_testing;
