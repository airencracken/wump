use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(dualvar weaken);
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

for my $original ('42', '42.5', '18446744073709551615', -42, 42.5, dualvar(7, 'seven'), !!1, !!0) {
	my $value = $original;
	RootFixture::scalar_publish(\$value);
	my $before = RootFixture::scalar_state(\$value);
	for my $kind (0, 1, 2, 3, 6, 7, 10) {
		my $result = RootFixture::scalar_read(\$value, $kind);
		is_deeply(RootFixture::scalar_state(\$value), $before, "read kind $kind preserves shared source state");
		if ($kind == 7 || $kind == 10) {
			ok(!Wump::is_shared(\$result), 'scalar copies start unclassified');
		}
	}
}

my $dual = dualvar(7, 'seven');
RootFixture::scalar_publish(\$dual);
my $copy = RootFixture::scalar_read(\$dual, 7);
is(0 + $copy, 7, 'a shared dual value keeps its numeric representation');
is("$copy", 'seven', 'a shared dual value keeps its string representation');
my $boolean = !!1;
RootFixture::scalar_publish(\$boolean);
my $bool_copy = RootFixture::scalar_read(\$boolean, 7);
ok(RootFixture::scalar_read(\$bool_copy, 11), 'copying a published boolean preserves boolean identity');

sub IsWumpReadRange { "0041\t0043\n20AC\n" }
my $property = eval 'qr/\p{IsWumpReadRange}/';
is($@, '', 'user-defined Unicode properties retain native inversion-list copies');
ok($property && 'B' =~ $property && "\x{20ac}" =~ $property, 'native property ranges match their members');
ok($property && 'D' !~ $property, 'native property ranges reject nonmembers');

WumpTest::check_program(q{
	use RootFixture;
	my $key = 'PATH';
	RootFixture::scalar_publish(\$key);
	my %hash = (PATH => 'original');
	{ local $hash{$key} = 'temporary'; print "$hash{PATH}\n" }
	print "$hash{PATH}\n";
}, 0, qr/\Atemporary\noriginal\n\z/, 'published key copies preserve stock hash localization save records');

my $latin_utf8 = "\xe9";
utf8::upgrade($latin_utf8);
for my $value ("\xe9", $latin_utf8, "\x{20ac}") {
	RootFixture::scalar_publish(\$value);
	my $before = RootFixture::scalar_state(\$value);
	my $utf8 = RootFixture::scalar_read(\$value, 5);
	is($utf8, $value, 'UTF-8 reads preserve character content');
	my $byte = eval { RootFixture::scalar_read(\$value, 4) };
	if (ord($value) > 255) { like($@, qr/Wide character/, 'wide byte conversion fails without changing its source') }
	else { is($byte, $value, 'byte reads preserve Latin-1 content') }
	is_deeply(RootFixture::scalar_state(\$value), $before, 'encoding reads preserve source bytes and flags');
	ok(!RootFixture::read_frame_active(), 'encoding failure or return leaves no active read frame');
}

our $named;
RootFixture::scalar_publish(\$named);
my (@warnings, $in_warning);
my $nested = 12.5;
RootFixture::scalar_publish(\$nested);
{
	local $SIG{__WARN__} = sub ($text) {
		push @warnings, $text;
		$in_warning = RootFixture::read_frame_active();
		RootFixture::scalar_read(\$nested, 3);
		yield;
	};
	my $ignored = $named + 1;
}
is(scalar @warnings, 1, 'one undefined read emits one warning');
like($warnings[0], qr/\$(?:main::)?named/, 'undefined diagnostics identify the original variable');
ok($in_warning, 'warnings execute inside the guarded source-read frame');
ok(!RootFixture::read_frame_active(), 'warning return restores the previous read frame');
{
	local $SIG{__WARN__} = sub { RootFixture::scalar_read(\$nested, 3); die "read warning failed\n" };
	eval { RootFixture::scalar_read(\$named, 0) };
	like($@, qr/read warning failed/, 'warning-hook exceptions propagate');
}
ok(!RootFixture::read_frame_active(), 'warning exceptions release read frames and pins');

my @source_cells = (undef);
my $only_reference = \$source_cells[0];
@source_cells = ();
my $weak_reference = $only_reference;
RootFixture::scalar_publish($only_reference);
my $pinned_in_warning;
{
	local $SIG{__WARN__} = sub {
		# Add backref magic after entry: preexisting non-publication magic
		# deliberately excludes a value from the plain-scalar read barrier.
		weaken($weak_reference);
		undef $only_reference;
		$pinned_in_warning = defined $weak_reference;
		yield;
	};
	RootFixture::scalar_read($only_reference, 0);
}
ok($pinned_in_warning, 'a read pins the source when a callback drops its last external reference');
ok(!defined $weak_reference, 'returning from a read drops its source pin');

my ($first, $second) = (1234, 5678);
RootFixture::scalar_publish(\$first);
RootFixture::scalar_publish(\$second);
my $wg = waitgroup;
add $wg;
act { $first = 999; RootFixture::scalar_read(\$second, 3); done $wg };
is(RootFixture::borrow_read(\$first, \$second), '1234', 'computed buffers survive a yield, source mutation, and another conversion');
await $wg;

my $forced = 123;
RootFixture::scalar_publish(\$forced);
is(RootFixture::scalar_read(\$forced, 8), '123', 'explicit force still returns the installed string');
RootFixture::scalar_read(\$forced, 9);
ok(utf8::is_utf8($forced), 'explicit UTF-8 upgrade still mutates the original published scalar');

my $readonly = '42.5';
RootFixture::scalar_publish(\$readonly);
Internals::SvREADONLY($readonly, 1);
my $readonly_before = RootFixture::scalar_state(\$readonly);
is(RootFixture::scalar_read(\$readonly, 2), 42.5, 'read-only published values can be numified');
is(RootFixture::scalar_read(\$readonly, 7), '42.5', 'read-only published values can be copied');
is_deeply(RootFixture::scalar_state(\$readonly), $readonly_before, 'read-only conversions preserve the original flags and storage');

{
	package ReadTie;
	sub TIESCALAR { bless {fetches => 0}, shift }
	sub FETCH ($self) { $self->{fetches}++; 42 }
}
tie my $tied, 'ReadTie';
RootFixture::scalar_publish(\$tied);
is(RootFixture::scalar_read(\$tied, 0), 42, 'tied values keep their upstream conversion behavior');
is(tied($tied)->{fetches}, 1, 'the read barrier does not add tied FETCH calls');

{
	package ReadOverload;
	use overload '0+' => sub ($self, @) { $self->{calls}++; Wump::yield(); 42 }, fallback => 1;
}
my $object = bless {calls => 0}, 'ReadOverload';
RootFixture::scalar_publish(\$object);
is(RootFixture::scalar_read(\$object, 0), 42, 'overloaded references retain their conversion hooks');
is($object->{calls}, 1, 'an overloaded numeric conversion runs once across a yield');

WumpTest::check_program(q{
	use Wump; use RootFixture;
	my $value;
	RootFixture::scalar_publish(\$value);
	my $ready = chan;
	my $park = chan;
	act {
		local $SIG{__WARN__} = sub { $ready->send(1); $park->recv };
		RootFixture::scalar_read(\$value, 0);
	};
	$ready->recv;
	print RootFixture::read_frame_active() ? "wrong frame\n" : "main has no read frame\n";
}, 0, qr/\Amain has no read frame\n\z/, 'abandoned read warnings release snapshots without exposing another act frame');
done_testing;
