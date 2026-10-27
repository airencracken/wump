use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'weaken';
use Wump;
use lib 'tests/perl/lib';
use WumpTest;
use RootFixture;

my (@native, @constant, @list, @opaque, @called);
with_tasks {
	my $out = chan(1);
	for my $kind (0..3) {
		my $payload = [{nested => []}];
		my $code = RootFixture::make($payload, $kind);
		my $before = Wump::is_shared($payload);
		$out->send($code);
		my $received = $out->recv;
		my $flags = [$before, Wump::is_shared($payload), Wump::is_shared($payload->[0]),
			Wump::is_shared($payload->[0]{nested})];
		if ($kind == 0) { @opaque = @$flags; $received->() }
		elsif ($kind == 1) { @native = @$flags }
		elsif ($kind == 2) { @constant = @$flags }
		else { @list = @$flags }
	}
	for my $kind (1, 2) {
		my $payload = [];
		my $code = RootFixture::make($payload, $kind);
		$code->();
		push @called, Wump::is_shared($payload);
	}
};
is_deeply(\@native, ['', 1, 1, 1], 'flagged XSUB payloads publish their complete reference graph');
is_deeply(\@constant, ['', 1, 1, 1], 'scalar constant subs publish their retained value');
is_deeply(\@list, ['', 1, 1, 1], 'list constant subs publish their retained array and nested references');
is_deeply(\@opaque, ['', '', '', ''], 'opaque unflagged XSUB pointers are never treated as SVs');
is_deeply(\@called, [1, 1], 'calling native subs from an act publishes supported native roots');

{
	package HiddenInlineConstant;
	use constant VALUE => {nested => []};
	sub value { VALUE }
}
my @inline;
with_tasks {
	my $value = HiddenInlineConstant::value();
	@inline = (Wump::is_shared($value), Wump::is_shared($value->{nested}));
};
is_deeply(\@inline, [1, 1], 'inlined reference constants in shared pads publish their referents');

use feature 'class';
no warnings 'experimental::class';
class HiddenRootBase {
	field $base = [];
	method base { $base }
}
class HiddenRootObject :isa(HiddenRootBase) {
	field $scalar = {nested => []};
	field @array = ([]);
	field %hash = (first => []);
	method flags {
		return [map { Wump::is_shared($_) } ($self->base, $scalar, $scalar->{nested}, $array[0], $hash{first})];
	}
	method replace {
		$scalar = {nested => []};
		$array[0] = [];
		$hash{first} = [];
	}
}
class HiddenRootEmpty { }

my ($before_class, $after_class, $after_write, $empty);
with_tasks {
	my $object = HiddenRootObject->new;
	$before_class = $object->flags;
	my $out = chan(1);
	$out->send($object);
	my $received = $out->recv;
	$after_class = $received->flags;
	$received->replace;
	$after_write = $received->flags;
	my $blank = HiddenRootEmpty->new;
	$out->send($blank);
	$empty = Wump::is_shared(scalar $out->recv);
};
is_deeply($before_class, [('', '', '', '', '')], 'new class fields begin unclassified');
is_deeply($after_class, [(1) x 5], 'publication follows inherited, scalar, array, and hash fields');
is_deeply($after_write, [(1) x 5], 'later assignments through published class fields publish new references');
ok($empty, 'zero-field class instances publish safely');

my $construct_out;
sub hidden_escape {
	$construct_out->send($_[0]);
	return [];
}
class HiddenRootEscaping {
	field $early = main::hidden_escape(RootFixture::constructor_self());
	field $scalar = {nested => []};
	field @array = ([]);
	field %hash = (first => []);
	method flags {
		return [map { Wump::is_shared($_) } ($early, $scalar, $scalar->{nested}, $array[0], $hash{first})];
	}
}
my $after_construct;
with_tasks {
	$construct_out = chan(1);
	my $object = HiddenRootEscaping->new;
	my $received = $construct_out->recv;
	$after_construct = $received->flags;
};
is_deeply($after_construct, [(1) x 5], 'fields initialized after the object escapes are published');
undef $construct_out;

my (@regex_before, @regex_after, @regex_calls);
with_tasks {
	my $payload = [];
	my $regex = qr/a(?{ push @$payload, 'called' })/;
	@regex_before = (Wump::is_shared($payload));
	my $out = chan(1);
	$out->send($regex);
	my $received = $out->recv;
	@regex_after = (Wump::is_shared($payload));
	'a' =~ $received;
	@regex_calls = @$payload;
};
is_deeply(\@regex_before, [''], 'a private regex does not eagerly publish its captured values');
is_deeply(\@regex_after, [1], 'regex publication follows its hidden callback CV and captures');
is_deeply(\@regex_calls, ['called'], 'publication does not execute regex code callbacks');

my ($embedded, $matched);
with_tasks {
	my $payload = [];
	my $inner = qr/a(?{ push @$payload, 1 })/;
	my $outer = qr/b${inner}c/;
	undef $inner;
	my $out = chan(1);
	$out->send($outer);
	my $received = $out->recv;
	$embedded = Wump::is_shared($payload);
	$matched = 'bac' =~ $received;
};
ok($embedded, 'native regex storage publishes interpolated regex captures');
ok($matched, 'interpolated regex remains executable after publication');

my (@copy_flags, @copy_calls);
with_tasks {
	my $payload = [];
	my $regex = qr/a(?{ push @$payload, 'copy' })/;
	my $copy = $$regex;
	undef $regex;
	push @copy_flags, Wump::is_shared($payload);
	my $out = chan(1);
	$out->send(\$copy);
	my $received = $out->recv;
	push @copy_flags, Wump::is_shared($payload);
	'a' =~ $$received;
	@copy_calls = @$payload;
};
is_deeply(\@copy_flags, ['', 1], 'lightweight regex copies publish roots retained by their mother regex');
is_deeply(\@copy_calls, ['copy'], 'a published regex copy retains its executable callback');

my ($unicode, $unicode_match);
with_tasks {
	my $regex = qr/(?<word>\p{Greek}+|alpha|bravo|charlie)/i;
	my $out = chan(1);
	$out->send($regex);
	my $received = $out->recv;
	$unicode_match = "\x{3b1}\x{3b2}" =~ $received;
	$unicode = $+{word};
};
ok($unicode_match, 'publication handles native Unicode and trie auxiliary data');
is($unicode, "\x{3b1}\x{3b2}", 'native regex capture values remain intact');

my $foreign_capture;
with_tasks {
	my $payload = [];
	my $code = sub { $payload };
	my $foreign = RootFixture::opaque_regex($code);
	my $out = chan(1);
	$out->send($foreign);
	$out->recv;
	$foreign_capture = Wump::is_shared($payload);
};
ok($foreign_capture, 'foreign regex common roots publish without dereferencing opaque private storage');

my ($destroyed, $weak) = (0, undef);
{
	package HiddenRootOwned;
	sub DESTROY { $destroyed++ }
}
with_tasks {
	my $out = chan(1);
	{
		my $payload = bless {}, 'HiddenRootOwned';
		$weak = $payload;
		weaken($weak);
		my $code = RootFixture::make($payload, 1);
		$out->send($code);
		$out->recv;
	}
};
is($destroyed, 1, 'walking native payloads does not retain their owned object');
is($weak, undef, 'native payload lifetime still invalidates weak references');

done_testing;
