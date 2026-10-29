use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'weaken';
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

my $ready = chan;
my $release = chan;
my $group = waitgroup;
for my $kind (0..2) {
	my $source;
	RootFixture::scalar_publish(\$source);
	add $group;
	act { RootFixture::memory_guard(\$source, sub { $ready->send(1); $release->recv }); done $group };
	$ready->recv;
	eval { RootFixture::vivify(\$source, $kind) };
	like($@, qr/concurrent mutation/, "vivification kind $kind rejects a foreign source writer before changing flags");
	$release->send(1); await $group;
	ok(!defined $source, "rejected kind $kind leaves its source undefined");
	RootFixture::vivify(\$source, $kind);
	is(ref($source), (qw(SCALAR ARRAY HASH))[$kind], "vivification kind $kind retains native reference type");
	ok(Wump::is_shared($source), "vivified kind $kind publishes its new referent");
}

my $private = [{nested => []}];
my $proxy = RootFixture::deferred($private, 4, 1);
ok(!Wump::is_shared($private), 'deferred owner starts private');
RootFixture::scalar_publish($proxy);
ok(Wump::is_shared($private), 'publishing a deferred proxy follows its owned aggregate');
ok(Wump::is_shared($private->[0]{nested}), 'publication follows the deferred owner graph recursively');

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my $array = [1]; my $weak = $array; weaken($weak);
	my $proxy = RootFixture::deferred($array, 5, 0);
	undef $array;
	$$proxy = 42;
	undef $proxy;
	die "nonextendible owner leaked\n" if defined $weak;
	print "nonextendible owner released\n";
}, 0, qr/\Anonextendible owner released\n\z/, 'nonextendible deferred write releases its old aggregate ownership');

# Compound assignment evaluates its lvalue before the RHS. The RHS observes
# the new head weakly and then lets another act remove its slot.
for my $case (
	['fast array', 'my @values;', '\\@values', '$values[3]'],
	['package array', 'our @values;', '\\@values', '$values[3]'],
	['generic array', 'my @values; sub index_value { 3 }', '\\@values', '$values[index_value()]'],
	['constant hash', 'my %values;', '\\%values', '$values{key}'],
	['generic hash', 'my %values; sub key_value { "key" }', '\\%values', '$values{key_value()}'],
	['UTF8 hash', 'my %values; my $key = "a\x{100}\0b";', '\\%values', '$values{$key}'],
	['nested array/hash', 'my @values;', '\\@values', '$values[0]{key}'],
	['nested hash/array', 'my %values;', '\\%values', '$values{key}[0]'],
) {
	my ($name, $setup, $container, $element) = @$case;
	WumpTest::check_program(qq{
		use Wump; use RootFixture; use Scalar::Util 'weaken';
		$setup
		RootFixture::scalar_publish($container);
		my \$weak;
		my \$go = chan; my \$finished = waitgroup; add \$finished;
		act { \$go->recv; delete $element; done \$finished };
		my \$answer = ($element += do {
			\$weak = \\$element;
			\$\$weak = 40;
			weaken(\$weak);
			\$go->send(1); await \$finished;
			die "created cell was freed\\n" unless defined \$weak;
			2
		});
		die "wrong created alias\\n" unless \$answer == 42;
		die "created cell leaked\\n" if defined \$weak;
		print "created alias retained\\n";
	}, 0, qr/\Acreated alias retained\n\z/, "$name created cell retains writable alias lifetime");
}

# Compare the protected path with native private containers. Deferred array
# holes and out-of-range negative indexes have different normalization rules.
sub array_aliases ($shared, $index, $write) {
	my @values = (10, 20, 30);
	delete $values[1];
	RootFixture::scalar_publish(\@values) if $shared;
	my $consume = sub { $_[0] = 42 if $write; return };
	my $error;
	{
		local $@;
		eval { $consume->($values[$index]) };
		$error = $@;
		$error =~ s/ at .*//s;
	}
	return [$error, scalar(@values), map { [exists($values[$_]) ? 1 : 0, $values[$_]] } 0..$#values];
}
for my $index (-5, -3, -2, -1, 0, 1, 2, 3, 8) {
	for my $write (0, 1) {
		is_deeply(array_aliases(1, $index, $write), array_aliases(0, $index, $write),
			"deferred array index $index preserves native " . ($write ? 'write' : 'unused alias') . ' behavior');
	}
}

for my $key ('', "nul\0key", "latin\x{e9}", "wide\x{100}") {
	my %values;
	RootFixture::scalar_publish(\%values);
	my $ignore = sub { return };
	$ignore->($values{$key});
	ok(!exists $values{$key}, 'unused deferred string-key alias leaves its slot absent');
	my $touch = sub { $_[0] = 42 };
	$touch->($values{$key});
	is($values{$key}, 42, 'deferred string-key alias creates the original key');
	is(scalar(keys %values), 1, 'deferred string-key write creates exactly one slot');
}

for my $create (0, 1) {
	my $owner = [];
	my $delegate = RootFixture::deferred($owner, 4, 1);
	RootFixture::scalar_publish($delegate);
	add $group;
	act { RootFixture::memory_guard($owner, sub { $ready->send(1); $release->recv }); done $group };
	$ready->recv;
	eval { RootFixture::resolve_deferred($delegate, $create) };
	like($@, qr/concurrent mutation/, "deferred resolution create=$create rejects a foreign container writer");
	is_deeply(RootFixture::lvalue_state($delegate), [1, 1], 'failed resolution leaves its ownership fields unresolved');
	$release->send(1); await $group;
	ok(!exists $owner->[4], 'failed resolution leaves the array slot absent');
	$$delegate = 42;
	is($owner->[4], 42, 'failed resolution releases its delegate guard and permits retry');
	ok(Wump::is_shared(\$owner->[4]), 'resolved deferred cell is published before it escapes');
}

WumpTest::check_program(q{
	use Wump; use RootFixture;
	my $opaque = RootFixture::opaque_lvalue();
	RootFixture::scalar_publish($opaque);
	die "opaque delegate not published\n" unless Wump::is_shared($opaque);
	print "opaque target skipped\n";
}, 0, qr/\Aopaque target skipped\n\z/, 'publication skips a native fake-pointer lvalue target');

for my $case (
	['array', 'my @values;', '\\@values', '$values[3]'],
	['hash', 'my %values;', '\\%values', '$values{key}'],
) {
	my ($name, $setup, $container, $element) = @$case;
	WumpTest::check_program(qq{
		use Wump; use RootFixture; use Scalar::Util 'weaken';
		$setup
		RootFixture::scalar_publish($container);
		my \$weak;
		eval { $element += do { \$weak = \\$element; weaken(\$weak); delete $element; die "RHS failed\\n" } };
		die "exception changed\\n" unless \$@ =~ /RHS failed/;
		die "created cell leaked\\n" if defined \$weak;
		$element = 42;
		die "container guard leaked\\n" unless $element == 42;
		print "creation unwind released\\n";
	}, 0, qr/\Acreation unwind released\n\z/, "$name creation releases its retained cell on exception");
}

WumpTest::check_program(q{
	use Wump; use RootFixture; use Scalar::Util 'weaken';
	my %values; RootFixture::scalar_publish(\%values);
	my $entered = chan; my $park = chan;
	act { $values{key} += do { delete $values{key}; $entered->send(1); $park->recv; 2 } };
	$entered->recv;
	print "created alias parked\n";
}, 0, qr/\Acreated alias parked\n\z/, 'abandoned creation releases its detached alias during task cleanup');

done_testing;
