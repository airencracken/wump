use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

# Sub arguments are writable aliases. The first argument must keep the same
# scalar head even when evaluating a later argument parks and loses its slot.
for my $case (
	['lexical fast array', 'my @values = (40);', '$values[0]', '\\@values', '$values[0]'],
	['package fast array', 'our @values = (40);', '$values[0]', '\\@values', '$values[0]'],
	['dynamic array', 'my @values = (40); my $index = 0;', '$values[$index]', '\\@values', '$values[0]'],
	['generic array', 'my @values = (40); sub get_index { 0 }', '$values[get_index()]', '\\@values', '$values[0]'],
	['negative array', 'my @values = (40);', '$values[-1]', '\\@values', '$values[0]'],
	['undefined array', 'my @values = (undef);', '$values[0]', '\\@values', '$values[0]'],
	['constant hash', 'my %values = (key => 40);', '$values{key}', '\\%values', '$values{key}'],
	['dynamic hash', 'my %values = (key => 40); my $key = "key";', '$values{$key}', '\\%values', '$values{key}'],
	['generic hash', 'my %values = (key => 40); sub get_key { "key" }', '$values{get_key()}', '\\%values', '$values{key}'],
	['undefined hash', 'my %values = (key => undef);', '$values{key}', '\\%values', '$values{key}'],
	['UTF8 hash', 'my $key = "a\x{100}\0b"; my %values = ($key => 40);', '$values{$key}', '\\%values', '$values{$key}'],
	['nested array', 'my @values = ([40]);', '$values[0][0]', '\\@values', '$values[0][0]'],
	['nested hash', 'my %values = (child => {key => 40});', '$values{child}{key}', '\\%values', '$values{child}{key}'],
) {
	my ($name, $setup, $expression, $container, $element) = @$case;
	for my $replacement (0, 1) {
		my $replace = $replacement ? "$element = 99;" : '';
		WumpTest::check_program(qq{
			use strict; use warnings; use Wump; use RootFixture;
			use Scalar::Util qw(weaken refaddr);
			$setup
			RootFixture::scalar_publish($container);
			my \$weak = \\$element; weaken(\$weak);
			my \$go = chan; my \$finished = waitgroup; add \$finished;
			act { \$go->recv; delete $element; $replace done \$finished };
			my \$consume = sub {
				die "argument alias changed\\n" unless refaddr(\\\$_[0]) == refaddr(\$weak);
				\$_[0] //= 40;
				\$_[0] += 2;
				\$_[0]
			};
			my \$answer = \$consume->($expression, do {
				\$go->send(1); await \$finished;
				die "argument head was freed\\n" unless defined \$weak;
				0
			});
			die "wrong alias result\\n" unless \$answer == 42;
			die "argument head leaked\\n" if defined \$weak;
			print "writable alias retained and released\\n";
		}, 0, qr/\Awritable alias retained and released\n\z/,
			"$name writable argument survives " . ($replacement ? 'replacement' : 'deletion'));
	}
}

# Both the body of a callee and the evaluation of a later argument may park.
WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util qw(weaken refaddr);
	my @array = (40); RootFixture::scalar_publish(\@array);
	my $weak = \$array[0]; weaken($weak);
	my $go = chan; my $finished = waitgroup; add $finished;
	act { $go->recv; delete $array[0]; done $finished };
	my $consume = sub {
		$go->send(1); await $finished;
		die "callee alias was freed\n" unless defined $weak;
		$_[0] += 2;
		$_[0]
	};
	my $answer = $consume->($array[0]);
	die "wrong callee result\n" unless $answer == 42;
	die "callee alias leaked\n" if defined $weak;
	print "callee alias retained\n";
}, 0, qr/\Acallee alias retained\n\z/, 'callee can park before updating a detached argument');

for my $case (
	['array', 'my @values = (40);', '\\@values', '$values[0]'],
	['hash', 'my %values = (key => 40);', '\\%values', '$values{key}'],
) {
	my ($name, $setup, $container, $element) = @$case;
	WumpTest::check_program(qq{
		use strict; use warnings; use Wump; use RootFixture;
		use Scalar::Util qw(weaken refaddr);
		$setup
		RootFixture::scalar_publish($container);
		my \$weak = \\$element; weaken(\$weak);
		my \$slot = sub :lvalue { $element };
		my \$go = chan; my \$group = waitgroup; add \$group;
		act { \$go->recv; delete $element; done \$group };
		my \$consume = sub {
			die "returned alias changed\\n" unless refaddr(\\\$_[0]) == refaddr(\$weak);
			\$_[0] += 2; \$_[0]
		};
		my \$answer = \$consume->(\$slot->(), do {
			\$go->send(1); await \$group;
			die "returned alias freed\\n" unless defined \$weak;
			0
		});
		die "wrong lvalue return\\n" unless \$answer == 42;
		die "returned alias leaked\\n" if defined \$weak;
		print "lvalue return retained\\n";
	}, 0, qr/\Alvalue return retained\n\z/, "$name lvalue return survives a yielding argument");
}

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my @values = (40); RootFixture::scalar_publish(\@values);
	my $weak = \$values[0]; weaken($weak);
	my $consume = sub { die "callee failed\n" };
	eval { $consume->($values[0], do { delete $values[0]; 0 }) };
	die "exception changed\n" unless $@ =~ /callee failed/;
	die "exception retained alias\n" if defined $weak;
	print "exception released alias\n";
}, 0, qr/\Aexception released alias\n\z/, 'callee exception releases a detached writable alias');

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my %values = (key => 40); RootFixture::scalar_publish(\%values);
	my $weak = \$values{key}; weaken($weak);
	my $entered = chan; my $park = chan;
	my $consume = sub { $_[0] = 42 };
	act { $consume->($values{key}, do { $entered->send(1); $park->recv; 0 }) };
	$entered->recv; delete $values{key};
	die "parked argument freed\n" unless defined $weak;
	print "writable argument parked\n";
}, 0, qr/\Awritable argument parked\n\z/, 'abandoned argument evaluation releases its retained alias');

my @array = (40);
my %hash = (key => 40);
RootFixture::scalar_publish(\@array);
RootFixture::scalar_publish(\%hash);
my ($ready, $release) = (chan, chan);
my $group = waitgroup;
my $consume = sub { $_[0] += 2 };
for my $case (
	['array', \@array, sub { $consume->($array[0]) }],
	['hash', \%hash, sub { $consume->($hash{key}) }],
) {
	add $group;
	act {
		RootFixture::memory_guard($case->[1], sub { $ready->send(1); $release->recv });
		done $group;
	};
	$ready->recv;
	eval { $case->[2]->() };
	like($@, qr/read overlaps mutation/, "$case->[0] writable lookup rejects a foreign container writer");
	$release->send(1);
	await $group;
}

my $touch = sub { $_[0] = 42 };
$touch->($array[0]);
$touch->($hash{key});
is($array[0], 42, 'ordinary array argument still aliases its slot');
is($hash{key}, 42, 'ordinary hash argument still aliases its slot');
{
	local $array[0] = 10;
	local $hash{key} = 20;
	$consume->($array[0]);
	$consume->($hash{key});
	is($array[0], 12, 'localized array alias updates its act view');
	is($hash{key}, 22, 'localized hash alias updates its act view');
}
is($array[0], 42, 'localized array write leaves base value intact');
is($hash{key}, 42, 'localized hash write leaves base value intact');
my $ignore = sub { return };
$ignore->($hash{absent});
ok(!exists $hash{absent}, 'unused deferred hash argument stays absent');
$touch->($hash{absent});
is($hash{absent}, 42, 'writing a deferred hash argument creates its slot');
my $index = 5;
$ignore->($array[$index]);
ok(!exists $array[$index], 'unused deferred array argument stays absent');
$touch->($array[$index]);
is($array[$index], 42, 'writing a deferred array argument creates its slot');
$array[1][0] = 7;
$hash{child}{key} = 8;
is($array[1][0], 7, 'missing array child retains autovivification');
is($hash{child}{key}, 8, 'missing hash child retains autovivification');
{
	package LvalueArray;
	sub TIEARRAY { bless {value => 40, gets => 0, sets => 0}, shift }
	sub FETCH { $_[0]{gets}++; Wump::yield(); $_[0]{value} }
	sub STORE { $_[0]{sets}++; $_[0]{value} = $_[2] }
	sub FETCHSIZE { 1 }
	package LvalueHash;
	sub TIEHASH { bless {value => 40, gets => 0, sets => 0}, shift }
	sub FETCH { $_[0]{gets}++; Wump::yield(); $_[0]{value} }
	sub STORE { $_[0]{sets}++; $_[0]{value} = $_[2] }
}
my $ta = tie my @tied_array, 'LvalueArray';
my $th = tie my %tied_hash, 'LvalueHash';
RootFixture::scalar_publish(\@tied_array);
RootFixture::scalar_publish(\%tied_hash);
$consume->($tied_array[0]);
$consume->($tied_hash{key});
is_deeply([@$ta{qw(value gets sets)}], [42, 1, 1], 'tied array alias retains one FETCH and STORE');
is_deeply([@$th{qw(value gets sets)}], [42, 1, 1], 'tied hash alias retains one FETCH and STORE');

done_testing;
