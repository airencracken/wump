use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use XS::APItest ();
use Wump;
use lib 'tests/perl/lib';
use WumpTest;

my (@private, @sent, $escaped);
scope {
	my $value = {child => [42]};
	@private = map { Wump::is_shared($_) } ($value, $value->{child}, \$value);
	my $out = chan(1);
	$out->send($value);
	@sent = map { Wump::is_shared($_) } ($value, $value->{child}, \$value);
	$escaped = $out->recv;
};
is_deeply(\@private, ['', '', ''], 'new task-local values begin unpublished');
is_deeply(\@sent, [1, 1, ''], 'channel publication marks the referent graph without marking the sender scalar');
ok(Wump::is_shared($escaped), 'publication metadata survives scope exit');

my (@captured, @inherited);
our $context;
scope {
	my $value = {child => []};
	my $out = chan;
	local $context = {data => []};
	act {
		$out->send([Wump::is_shared($value), Wump::is_shared($value->{child}),
			Wump::is_shared($context), Wump::is_shared($context->{data})]);
	};
	@captured = (Wump::is_shared($value), Wump::is_shared(\$value));
	@inherited = @{$out->recv};
};
is_deeply(\@captured, [1, 1], 'spawn publishes captured lexical cells and their references');
is_deeply(\@inherited, [1, 1, 1, 1], 'child snapshots publish references held by inherited bindings');

my (@clones, @clone_captures);
scope {
	my $out = chan;
	for (1..3) {
		my $value = [];
		my $closure = sub { return $value };
		push @clones, Wump::is_shared($closure);
		act { $out->send(Wump::is_shared($closure->())) };
		push @clone_captures, scalar $out->recv;
	}
};
is_deeply(\@clones, [('', '', '')], 'new CV instances do not inherit publication from their prototypes');
is_deeply(\@clone_captures, [1, 1, 1], 'each escaping closure publishes its actual captured pad');

my @stores;
our ($package_scalar, @package_array, %package_hash);
scope {
	my $scalar = [];
	my $array = [];
	my $hash = [];
	$package_scalar = $scalar;
	push @package_array, $array;
	$package_hash{new} = $hash;
	@stores = map { Wump::is_shared($_) } ($scalar, $array, $hash);
	my $later = {deep => []};
	$package_hash{later} = undef;
	$package_hash{later} = $later;
	push @stores, Wump::is_shared($later), Wump::is_shared($later->{deep});
	my $native = {nested => []};
	XS::APItest::Hash::store(\%package_hash, 'native', $native);
	push @stores, Wump::is_shared($native), Wump::is_shared($native->{nested});
};
is_deeply(\@stores, [(1) x 7], 'package stores, later scalar assignments, and native hash stores publish new graphs');

my @mutations;
scope {
	my $root = {array => [], scalar => undef};
	my $out = chan(1);
	$out->send($root);
	$out->recv;
	my @values = map { [] } 1..5;
	push @{$root->{array}}, $values[0];
	unshift @{$root->{array}}, $values[1];
	splice @{$root->{array}}, 1, 0, $values[2];
	$root->{scalar} = $values[3];
	@{$root->{array}} = ($values[4]);
	@mutations = map { Wump::is_shared($_) } @values;
};
is_deeply(\@mutations, [(1) x 5], 'shared array bulk mutations and scalar stores propagate publication');

my $outside = {new => []};
$escaped->{outside} = $outside;
ok(Wump::is_shared($outside) && Wump::is_shared($outside->{new}), 'stores after scope exit propagate into previously published containers');

my ($fetches, $stringifies) = (0, 0);
{
	package PublicationTie;
	sub TIEHASH { bless {hidden => []}, $_[0] }
	sub FIRSTKEY { $fetches++; return }
	sub NEXTKEY { $fetches++; return }
	sub FETCH { $fetches++; return }
	package PublicationString;
	use overload '""' => sub { $stringifies++; return 'object' }, fallback => 1;
}
my @magic;
scope {
	my %tied;
	my $tie = tie %tied, 'PublicationTie';
	my $object = bless {value => []}, 'PublicationString';
	my $out = chan(1);
	$out->send([\%tied, $object]);
	$out->recv;
	@magic = (Wump::is_shared($tie), Wump::is_shared($tie->{hidden}), Wump::is_shared($object->{value}));
};
is_deeply(\@magic, [1, 1, 1], 'raw publication reaches tie objects and blessed storage');
is_deeply([$fetches, $stringifies], [0, 0], 'publication invokes no FETCH, iteration, or overloaded stringification callbacks');

my ($deep, $cycle);
scope {
	my $value = [];
	my $tail = $value;
	for (1..4096) { my $next = []; push @$tail, $next; $tail = $next }
	push @$tail, $value;
	my $out = chan(1);
	$out->send($value);
	my $received = $out->recv;
	$deep = Wump::is_shared($tail);
	$cycle = refaddr($received) == refaddr($tail->[0]);
	pop @$tail;
};
ok($deep, 'deep publication uses an iterative walk');
ok($cycle, 'cyclic publication terminates without changing identity');

my ($destroyed, $weak) = (0, undef);
{
	package PublishedOwned;
	sub DESTROY { $destroyed++ }
}
scope {
	my $out = chan(1);
	{
		my $object = bless {}, 'PublishedOwned';
		$weak = $object;
		weaken($weak);
		$out->send($object);
		$out->recv;
	}
};
is($destroyed, 1, 'metadata does not retain published objects');
is($weak, undef, 'weak references expire after published values lose their owners');

my (@local, @state);
our $localized = {root => []};
sub shared_state {
	state $value = [];
	return Wump::is_shared($value);
}
scope {
	local $localized = {private => []};
	@local = (Wump::is_shared($localized), Wump::is_shared($localized->{private}));
	@state = (shared_state(), shared_state());
};
is_deeply(\@local, ['', ''], 'ordinary local bindings remain private until inherited or explicitly published');
is_deeply(\@state, [1, 1], 'state cells used by shared subs publish their initialized references');

my $usage;
eval { Wump::is_shared(42) };
$usage = $@;
like($usage, qr/Usage: Wump::is_shared/, 'publication diagnostics require a reference');

my ($readonly, $readonly_error);
scope {
	my $value = \42;
	my $out = chan(1);
	$out->send($value);
	$out->recv;
	$readonly = Wump::is_shared($value);
	eval { $$value = 43 };
	$readonly_error = $@;
};
ok($readonly, 'read-only referents can be published');
like($readonly_error, qr/read-only/, 'metadata preserves read-only protection');

my ($compilation, $compile_error, @compile_warnings);
scope {
	local $SIG{__WARN__} = sub { push @compile_warnings, $_[0] };
	my $symbols = \%PublicationCompilation::;
	$compilation = eval q{
		no feature 'signatures';
		package PublicationNoImport;
		BEGIN { $INC{'PublicationNoImport.pm'} = __FILE__ }
		package PublicationCompilation;
		use PublicationNoImport;
		sub forwarded ();
		sub forwarded () { 42 }
		[defined(&PublicationNoImport::import) ? 1 : 0, prototype(\&forwarded), forwarded()];
	};
	$compile_error = $@;
};
is($compile_error, '', 'publication leaves runtime module import and forward declaration rules intact');
is_deeply(\@compile_warnings, [], 'publication creates no spurious prototype warnings');
is_deeply($compilation, [0, '', 42], 'uninitialized stash entries retain their native meaning');

our @snapshot_values;
my $snapshot_flags;
scope {
	local @snapshot_values = ([]);
	my $out = chan;
	act {
		$out->send([Wump::is_shared(\@snapshot_values), Wump::is_shared(\$snapshot_values[0]),
			Wump::is_shared($snapshot_values[0])]);
	};
	$snapshot_flags = $out->recv;
};
is_deeply($snapshot_flags, ['', '', 1], 'shallow snapshot containers and cells stay private while referents escape');

check_program(q{
	use Wump;
	our $teardown_values = {};
	package PublicationTeardown {
		sub DESTROY {
			$main::teardown_values->{saved} = [];
			print Wump::is_shared($main::teardown_values->{saved}) ? "published\n" : "private\n";
		}
	}
	my $published = $teardown_values;
	my $park = chan;
	act { my $owned = bless {}, 'PublicationTeardown'; $park->recv };
	yield;
}, 0, qr/\Apublished\n\z/, 'abandoned-task destructors publish values saved in shared storage');

done_testing;
