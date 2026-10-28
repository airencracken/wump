use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'dualvar';
use Wump;
use RootFixture;

my @kinds = (0..7, 10, 12..37);
for my $initial (42, 18446744073709551615, 42.5, '42', dualvar(7, 'seven')) {
	my $value = $initial;
	RootFixture::scalar_publish(\$value);
	my ($ready, $release) = (chan, chan);
	my $group = waitgroup;
	add $group;
	act {
		RootFixture::memory_guard(\$value, sub { $ready->send(1); $release->recv });
		done $group;
	};
	$ready->recv;
	for my $kind (@kinds) {
		eval { RootFixture::scalar_read(\$value, $kind) };
		like($@, qr/read overlaps mutation/, "read $kind rejects a foreign writer before accessing cached or computed data");
	}
	$release->send(1);
	await $group;
	is(RootFixture::scalar_read(\$value, 7), $initial, 'rejected readers preserve the value and release their captures');
}

for my $value (undef, '', '0', '1', '42', "\xe9", "\x{20ac}") {
	RootFixture::scalar_publish(\$value);
	my $before = RootFixture::scalar_state(\$value);
	for my $kind (25, 26, 31, 32) {
		my @warnings;
		local $SIG{__WARN__} = sub { push @warnings, @_ };
		my $result = eval { RootFixture::scalar_read(\$value, $kind) };
		if (!defined $value) {
			is($@, '', 'or-null conversion of undef does not throw');
			ok(!defined $result, 'or-null macro returns undef without a warning');
			is(scalar @warnings, 0, 'or-null conversion does not invoke a warning hook');
		} elsif ($kind % 2 && $value eq "\x{20ac}") {
			like($@, qr/Wide character/, 'byte macro rejects a wide character');
		} else {
			is($@, '', 'encoded macro conversion succeeds');
			is($result, $value, 'encoded macro preserves character content');
		}
	}
	is_deeply(RootFixture::scalar_state(\$value), $before, 'encoded and or-null macros preserve source flags and storage');
}

for my $kind (3, 4) {
	my $value = "cached encoding with embedded\0NUL and \xe9";
	RootFixture::scalar_publish(\$value);
	RootFixture::memory_replace(\$value, "owned encoding with embedded\0NUL and \xe9");
	utf8::upgrade($value) if $kind == 4;
	my $original = $value;
	my $result = RootFixture::memory_borrow(\$value, $kind, sub {
		yield;
		RootFixture::memory_replace(\$value, 'replaced');
	});
	is($result, $original, "cached encoded macro $kind retains its buffer across replacement and a yield");
	is($value, 'replaced', 'the live encoded scalar receives its replacement');
}

{
	package ClaimTie;
	our $fetches = 0;
	sub TIESCALAR { bless {}, $_[0] }
	sub FETCH { $fetches++; Wump::yield(); 42 }
}
tie my $tied, 'ClaimTie';
RootFixture::scalar_publish(\$tied);
for my $kind (0, 1, 2, 6, 16, 22, 23) {
	my $before = $ClaimTie::fetches;
	RootFixture::scalar_read(\$tied, $kind);
	is($ClaimTie::fetches - $before, 1, "read $kind performs one yielding FETCH");
}

my $same_actor = 42;
RootFixture::scalar_publish(\$same_actor);
RootFixture::memory_guard(\$same_actor, sub {
	is(RootFixture::scalar_read(\$same_actor, 0), 42, 'a writer can read its own numeric cache');
	is(RootFixture::scalar_read(\$same_actor, 7), 42, 'a writer can snapshot its own value');
});
my $stats = RootFixture::memory_stats();
is_deeply([@$stats[0, 1]], [0, 0], 'read errors, conversions and callbacks leave the lifetime domain quiescent');
done_testing;
