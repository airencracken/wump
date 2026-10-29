use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use Hash::Util qw(lock_keys);
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

# Each expression loads its left operand before the RHS lets a writer remove
# that element. A weak reference observes the head without extending its life.
# Fail before using a dangling stack pointer on an unpatched interpreter.
for my $case (
	['lexical fast array', 'my @values = (40);', '$values[0]', '\\@values', '$values[0]'],
	['package fast array', 'our @values = (40);', '$values[0]', '\\@values', '$values[0]'],
	['dynamic array', 'my @values = (40); my $index = 0;', '$values[$index]', '\\@values', '$values[0]'],
	['generic array', 'my @values = (40); sub get_index { 0 }', '$values[get_index()]', '\\@values', '$values[0]'],
	['negative array', 'my @values = (40);', '$values[-1]', '\\@values', '$values[0]'],
	['constant hash', 'my %values = (key => 40);', '$values{key}', '\\%values', '$values{key}'],
	['dynamic hash', 'my %values = (key => 40); my $key = "key";', '$values{$key}', '\\%values', '$values{key}'],
	['generic hash', 'my %values = (key => 40); sub key { "key" }', '$values{key()}', '\\%values', '$values{key}'],
	['UTF8 hash', 'my $key = "a\x{100}\0b"; my %values = ($key => 40);', '$values{$key}', '\\%values', '$values{$key}'],
	['downgradable hash', 'my $key = "\x{e9}"; utf8::upgrade($key); my %values = ($key => 40);', '$values{$key}', '\\%values', '$values{$key}'],
) {
	my ($name, $setup, $expression, $container, $element) = @$case;
	for my $action ('delete', 'replace') {
		my $change = $action eq 'delete' ? "delete $element" : "delete $element; $element = 99";
		my $code = qq{
			use strict; use warnings; use Wump; use RootFixture;
			use Scalar::Util 'weaken';
			$setup
			RootFixture::scalar_publish($container);
			my \$weak = \\$element;
			weaken(\$weak);
			my \$go = chan;
			my \$finished = waitgroup;
			add \$finished;
			act { \$go->recv; $change; done \$finished };
			my \$answer = $expression + do {
				\$go->send(1);
				await \$finished;
				die "loaded head was freed\\n" unless defined \$weak;
				# This proves that the stack retains the original alias,
				# rather than silently substituting a scalar snapshot.
				\$\$weak = 80;
				2
			};
			die "wrong result: \$answer\\n" unless \$answer == 82;
			die "loaded head leaked\\n" if defined \$weak;
			print "retained, aliased, released\\n";
		};
		WumpTest::check_program($code, 0, qr/\Aretained, aliased, released\n\z/, "$name survives $action");
	}
}

for my $case (
	['array', 'my @parents = ({key => 40});', '\\@parents', '$parents[0]', '$parents[0]{$delayed_key->()}'],
	['hash', 'my %parents = (child => {key => 40});', '\\%parents', '$parents{child}', '$parents{child}{$delayed_key->()}'],
) {
	my ($name, $setup, $container, $element, $expression) = @$case;
	WumpTest::check_program(qq{
		use strict; use warnings; use Wump; use RootFixture;
		use Scalar::Util 'weaken';
		$setup
		RootFixture::scalar_publish($container);
		my \$weak = \\$element; weaken(\$weak);
		my \$go = chan;
		my \$finished = waitgroup; add \$finished;
		act { \$go->recv; delete $element; done \$finished };
		my \$delayed_key = sub {
			\$go->send(1); await \$finished;
			die "intermediate head was freed\\n" unless defined \$weak;
			'key'
		};
		my \$answer = $expression + 2;
		die "wrong nested result\\n" unless \$answer == 42;
		die "intermediate head leaked\\n" if defined \$weak;
		print "nested lookup retained\\n";
	}, 0, qr/\Anested lookup retained\n\z/, "$name intermediate survives a yielding key callback");
}

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my @array = (40); RootFixture::scalar_publish(\@array);
	my $weak = \$array[0]; weaken($weak);
	my $go = chan; my $entered = chan;
	act {
		my $unused = $array[0] + do { $entered->send(1); $go->recv; 2 };
	};
	$entered->recv;
	delete $array[0];
	die "abandoned operand lost its pin\n" unless defined $weak;
	print "operand parked\n";
}, 0, qr/\Aoperand parked\n\z/, 'abandoned expression releases its retained operand during task teardown');

{
	my @values = (40);
	RootFixture::scalar_publish(\@values);
	my $weak = \$values[0]; weaken($weak);
	eval { my $unused = $values[0] + do { delete $values[0]; die "load callback exception\n" } };
	like($@, qr/load callback exception/, 'exception after a load propagates normally');
	ok(!defined $weak, 'exception unwind releases the retained element head');
}

my @array = (40, undef, 42);
my %hash = (key => 40);
RootFixture::scalar_publish(\@array);
RootFixture::scalar_publish(\%hash);
is($array[-1] + 0, 42, 'negative index resolves inside the container claim');
ok(!defined $array[1], 'existing undef retains its value');
ok(!defined $array[20], 'out of bounds read returns undef');
ok(!defined $array[-20], 'negative out of bounds read returns undef');
ok(!defined $hash{absent}, 'absent key returns undef');
ok(!exists $hash{absent}, 'read does not create an absent key');
my ($ready, $release) = (chan, chan);
my $group = waitgroup;
add $group;
act {
	RootFixture::memory_guard(\@array, sub { $ready->send(1); $release->recv });
	done $group;
};
$ready->recv;
eval { my $unused = $array[0] + 2 };
like($@, qr/read overlaps mutation/, 'fast array lookup rejects a foreign writer');
$release->send(1);
await $group;
add $group;
act {
	RootFixture::memory_guard(\%hash, sub { $ready->send(1); $release->recv });
	done $group;
};
$ready->recv;
eval { my $unused = $hash{key} + 2 };
like($@, qr/read overlaps mutation/, 'hash lookup rejects a foreign writer');
$release->send(1);
await $group;
RootFixture::memory_guard(\@array, sub { is($array[0] + 2, 42, 'array read inside its own writer retains the element') });
RootFixture::memory_guard(\%hash, sub { is($hash{key} + 2, 42, 'hash read inside its own writer retains the element') });

# Existing callback and per-act element views must remain authoritative.
{
	local $array[0] = 10;
	local $hash{key} = 20;
	is($array[0] + 2, 12, 'active localized array element uses its act view');
	is($hash{key} + 2, 22, 'active localized hash element uses its act view');
}
is($array[0] + 2, 42, 'array localization restores the shared view');
is($hash{key} + 2, 42, 'hash localization restores the shared view');
{
	package LoadKey;
	sub TIESCALAR { bless {fetches => 0}, shift }
	sub FETCH { $_[0]{fetches}++; Wump::yield(); 'key' }
	package LoadHash;
	sub TIEHASH { bless {fetches => 0}, shift }
	sub FETCH { $_[0]{fetches}++; Wump::yield(); 40 }
}
my $key_object = tie my $key, 'LoadKey';
is($hash{$key} + 2, 42, 'tied key keeps its conversion path');
is($key_object->{fetches}, 1, 'key classification adds no FETCH');
my $hash_object = tie my %tied_hash, 'LoadHash';
is($tied_hash{key} + 2, 42, 'tied hash keeps its FETCH path');
is($hash_object->{fetches}, 1, 'container classification adds no FETCH');
my %numbers = (42 => 40);
RootFixture::scalar_publish(\%numbers);
my $number = 42;
is($numbers{$number} + 2, 42, 'numeric key retains native stringification');

my %restricted = (key => 40);
lock_keys(%restricted);
RootFixture::scalar_publish(\%restricted);
is($restricted{key} + 2, 42, 'existing restricted-hash key retains its value');
my $diagnosed = 0;
{
	local $SIG{__DIE__} = sub {
		yield;
		RootFixture::memory_guard(\%restricted, sub { $diagnosed++ });
	};
	eval { my $unused = $restricted{absent} + 2 };
	like($@, qr/disallowed key.*absent/, 'restricted-hash miss retains its native diagnostic');
}
is($diagnosed, 1, 'restricted-hash diagnostic invokes its die hook without a container claim');

done_testing;
