use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
use lib 'tests/perl/lib';
use WumpTest;

our (@array, %hash);
@array = ('global', 'shared');
%hash = (name => 'global', shared => 'global');
my (@seen, $root);
scope {
	my $out = chan;
	for my $name ('alpha', 'bravo') {
		act {
			local $array[0] = $name;
			local $hash{name} = $name;
			yield;
			$out->send([$array[0], $hash{name}, [@array], {%hash}]);
		};
	}
	push @seen, scalar $out->recv for 1..2;
	$root = [@array, {%hash}];
};
is_deeply([sort {$a->[0] cmp $b->[0]} @seen], [
	['alpha', 'alpha', ['alpha', 'shared'], {name => 'alpha', shared => 'global'}],
	['bravo', 'bravo', ['bravo', 'shared'], {name => 'bravo', shared => 'global'}],
], 'element bindings survive yields and whole-aggregate reads');
is_deeply($root, ['global', 'shared', {name => 'global', shared => 'global'}], 'unlocalized task sees only global cells');
is_deeply([@array, {%hash}], $root, 'scope exit leaves global aggregates intact');

my (@shared_seen, $private);
scope {
	my $ready = chan;
	my $resume = chan;
	my $out = chan;
	act {
		local $array[0] = 'private';
		local $hash{name} = 'private';
		$array[1] = 'from private task';
		$hash{shared} = 'from private task';
		$ready->send(1);
		$resume->recv;
		$out->send([$array[0], $hash{name}, $array[1], $hash{shared}]);
	};
	$ready->recv;
	@shared_seen = ($array[1], $hash{shared});
	$array[0] = 'new global';
	$hash{name} = 'new global';
	$array[1] = 'new shared';
	$hash{shared} = 'new shared';
	$resume->send(1);
	$private = $out->recv;
};
is_deeply(\@shared_seen, ['from private task', 'from private task'], 'unlocalized writes from a localized task remain shared');
is_deeply($private, ['private', 'private', 'new shared', 'new shared'], 'parked overlays retain their cells and observe other global writes');
is_deeply([@array, {%hash}], ['new global', 'new shared', {name => 'new global', shared => 'new shared'}], 'unwinding cannot overwrite newer global writes');

my ($missing, $after_delete);
scope {
	local $array[7] = 'far';
	local $hash{missing} = 'new key';
	local $hash{name} = 'temporary';
	$missing = [$#array, scalar @array, exists $array[6], exists $array[7],
		$array[-1], exists $hash{missing}, scalar keys %hash, scalar %hash];
	delete $hash{name};
	$after_delete = [exists $hash{name}, $hash{name}, [sort keys %hash]];
	yield;
};
is_deeply($missing, [7, 8, '', 1, 'far', 1, 3, 3], 'missing elements have task-local existence, extent, negative indexing and key counts');
is_deeply($after_delete, ['', undef, ['missing', 'shared']], 'deleting a localized hash key masks the global key');
is(scalar @array, 2, 'out-of-range localization does not extend the base array');
ok(!exists $hash{missing}, 'localizing a missing key never inserts it globally');
is($hash{name}, 'new global', 'deleting a local key leaves its global value intact');

my ($nested, @restored);
scope {
	local @array[0, 3] = ('outer', 'far outer');
	local @hash{'name', 'extra'} = ('outer', 'extra outer');
	eval {
		local @array[0, 3] = ('inner', 'far inner');
		local @hash{'name', 'extra'} = ('inner', 'extra inner');
		yield;
		$nested = [$array[0], $array[3], $hash{name}, $hash{extra}];
		die "nested failure\n";
	};
	@restored = ($array[0], $array[3], $hash{name}, $hash{extra}, $@);
};
is_deeply($nested, ['inner', 'far inner', 'inner', 'extra inner'], 'nested array/hash slices localize each selected element');
is_deeply(\@restored, ['outer', 'far outer', 'outer', 'extra outer', "nested failure\n"], 'caught exception restores enclosing slice bindings');

my ($inherited, $parent, $grandchild);
scope {
	my $go = chan;
	my $out = chan;
	{
		local $array[0] = 'at spawn';
		local $hash{name} = 'at spawn';
		local $hash{gone} = 'delete me';
		delete $hash{gone};
		act {
			$go->recv;
			$inherited = [$array[0], $hash{name}, exists $hash{gone}];
			$array[0] = 'child';
			$hash{name} = 'child';
			act { $out->send([$array[0], $hash{name}, exists $hash{gone}]) };
		};
		$array[0] = 'parent';
		$hash{name} = 'parent';
		$parent = [$array[0], $hash{name}];
	}
	$go->send(1);
	$grandchild = $out->recv;
};
is_deeply($inherited, ['at spawn', 'at spawn', ''], 'child inherits element snapshots and deletion masks after parent scope exit');
is_deeply($parent, ['parent', 'parent'], 'parent mutations stay in its own bindings');
is_deeply($grandchild, ['child', 'child', ''], 'modified inherited elements propagate to grandchildren');

my (@references, $escaped_array, $escaped_hash);
my ($array_ref, $hash_ref) = (\@array, \%hash);
my ($old_a, $old_h) = (\$array[0], \$hash{name});
scope {
	local $array_ref->[0] = 'via reference';
	local $hash_ref->{name} = 'via reference';
	$escaped_array = \$array[0];
	$escaped_hash = \$hash{name};
	@references = ($array[0], $hash{name}, $$old_a, $$old_h);
};
is_deeply(\@references, ['via reference', 'via reference', 'new global', 'new global'], 'aggregate aliases see overlays while original scalar references keep their identities');
is_deeply([$$escaped_array, $$escaped_hash], ['via reference', 'via reference'], 'references to localized element cells survive scope exit');

my ($whole, $iteration);
scope {
	my $out = chan;
	local @array = ('local whole', 'local shared');
	local %hash = (name => 'local whole', other => 2);
	local $array[0] = 'element';
	local $hash{name} = 'element';
	local $hash{added} = 'added';
	my ($first) = each %hash;
	act { $out->send([[@array], {%hash}]) };
	$whole = $out->recv;
	my @remaining;
	while (my ($key) = each %hash) { push @remaining, $key }
	$iteration = [$first, @remaining];
};
is_deeply($whole, [['element', 'local shared'], {name => 'element', other => 2, added => 'added'}], 'whole-container snapshots include visible element overlays');
is_deeply([sort @$iteration], ['added', 'name', 'other'], 'spawn snapshot preserves the parent merged hash iterator');

my ($unicode, $hash_values, $array_loop);
scope {
	local $hash{"\x{e9}"} = 'unicode';
	local $hash{"nul\0key"} = 'binary';
	my $latin1 = "\x{e9}";
	utf8::upgrade($latin1);
	$unicode = [$hash{$latin1}, $hash{"nul\0key"}];
	$hash_values = [sort values %hash];
	local $array[0] = 'foreach';
	my @copy;
	for (@array) { push @copy, $_ }
	$array_loop = \@copy;
};
is_deeply($unicode, ['unicode', 'binary'], 'canonical Unicode and embedded-NUL keys address the same bindings');
is_deeply($hash_values, [sort ('new global', 'new shared', 'unicode', 'binary')], 'values enumerates the merged hash view');
is_deeply($array_loop, ['foreach', 'new shared'], 'foreach uses localized array cells');

sub localized_argument {
	local $_[0] = 'local argument';
	yield;
	return [@_];
}
my ($arguments, $argument_after);
scope {
	my $argument = 'caller argument';
	$arguments = localized_argument($argument, 'second');
	$argument_after = $argument;
};
is_deeply($arguments, ['local argument', 'second'], 'localized argument elements survive yields and sub return');
is($argument_after, 'caller argument', 'argument-element localization preserves the original caller alias');

my ($changed_base, $base_after);
scope {
	my @base_array = ('first', 'second');
	my %base_hash = (name => 'first', other => 'second');
	my $ready = chan;
	my $resume = chan;
	my $out = chan;
	act {
		local $base_array[4] = 'local last';
		local $base_hash{name} = 'local name';
		$ready->send(1);
		$resume->recv;
		$out->send([[@base_array], {%base_hash}]);
	};
	$ready->recv;
	shift @base_array;
	push @base_array, 'new second';
	%base_hash = (new => 'new key');
	$resume->send(1);
	$changed_base = $out->recv;
	$base_after = [[@base_array], {%base_hash}];
};
is_deeply($changed_base, [['second', 'new second', undef, undef, 'local last'], {name => 'local name', new => 'new key'}],
	'element overlays remain visible across structural changes by an unlocalized task');
is_deeply($base_after, [['second', 'new second'], {new => 'new key'}], 'other tasks structural writes remain in the base');

my @structural_errors;
scope {
	local $array[0] = 'held';
	local $hash{name} = 'held';
	my @forms = (
		sub { push @array, 'bad' }, sub { pop @array },
		sub { shift @array }, sub { unshift @array, 'bad' },
		sub { splice @array, 0, 1 }, sub { $#array = 0 },
		sub { @array = ('bad') }, sub { undef @array },
		sub { delete $array[0] }, sub { %hash = (bad => 1) },
		sub { undef %hash },
		sub { @array = reverse @array }, sub { @array = sort @array },
	);
	for my $form (@forms) { eval { $form->() }; push @structural_errors, $@ }
};
like($_, qr/structural mutation with active element bindings/, 'structural operation fails explicitly before changing the base') for @structural_errors;
is_deeply([@array, {%hash}], ['new global', 'new shared', {name => 'new global', shared => 'new shared'}], 'rejected structural operations preserve shared aggregates');

my (@failures, $fetches);
$fetches = 0;
{
	package ElementTied;
	sub TIESCALAR { bless {}, shift }
	sub FETCH { $fetches++; 'tied' }
	sub STORE {}
}
my @tied = ('plain');
tie $tied[0], 'ElementTied';
scope {
	for my $form (sub { local $tied[0] }, sub { local $array[-100] },
		sub { local $ENV{WUMP_ELEMENT_TEST} }, sub { delete local $hash{name} }) {
		eval { $form->() };
		push @failures, $@;
	}
};
like($failures[0], qr/magic variable localization/, 'tied element localization is rejected');
is($fetches, 0, 'validation does not call FETCH');
like($failures[1], qr/array index outside/, 'negative index outside the visible array fails');
like($failures[2], qr/magic variable localization/, 'environment elements remain explicitly unsupported');
like($failures[3], qr/delete localization/, 'delete local remains explicitly unsupported');

{
	use feature qw(refaliasing declared_refs);
	no warnings qw(experimental::refaliasing experimental::declared_refs);
	my $replacement = 'replacement';
	my @alias_errors;
	my @forms = (
		sub { local \$array[0] = \$replacement },
		sub { local \$hash{name} = \$replacement },
		sub { local \(@array[0, 1]) = (\$replacement, \$replacement) },
		sub { local \(@hash{'name', 'shared'}) = (\$replacement, \$replacement) },
	);
	scope {
		for my $form (@forms) { eval { $form->() }; push @alias_errors, $@ }
	};
	like($_, qr/reference alias localization/, 'experimental element alias localization cannot bypass task isolation') for @alias_errors;
	is_deeply([@array, {%hash}], ['new global', 'new shared', {name => 'new global', shared => 'new shared'}],
		'rejected reference aliases preserve the original aggregates');
}

{
	package ElementOwned;
	sub DESTROY { ${$_[0]->{counter}}++ }
}
my ($scope_destroyed, $destroyed_at_scope_exit) = (0, 0);
scope {
	{
		local $hash{owned} = bless {counter => \$scope_destroyed}, 'ElementOwned';
		my @keys = keys %hash;
	}
	$destroyed_at_scope_exit = $scope_destroyed;
};
is($destroyed_at_scope_exit, 1, 'merged iteration releases scoped values when the binding unwinds');
my $container_destroyed = 0;
scope {
	{
		my %container = (owned => bless {counter => \$container_destroyed}, 'ElementOwned');
		local $container{temporary} = 'local';
		my @keys = keys %container;
	}
	$destroyed_at_scope_exit = $container_destroyed;
};
is($destroyed_at_scope_exit, 1, 'retired iteration views do not retain an otherwise dead aggregate');

my (@hidden_lifetimes, @visible_children);
for my $kind ('array', 'hash') {
	my $released = 0;
	scope {
		my $out = chan;
		{
			if ($kind eq 'array') {
				local $array[0] = bless {counter => \$released}, 'ElementOwned';
				{
					local $array[0] = 'visible';
					act { $out->send($array[0]) };
				}
			} else {
				local $hash{name} = bless {counter => \$released}, 'ElementOwned';
				{
					local $hash{name} = 'visible';
					act { $out->send($hash{name}) };
				}
			}
		}
		push @hidden_lifetimes, $released;
		push @visible_children, scalar $out->recv;
	};
}
is_deeply(\@hidden_lifetimes, [1, 1], 'snapshots do not keep hidden outer element values alive');
is_deeply(\@visible_children, ['visible', 'visible'], 'snapshots preserve the visible binding precedence');

my ($shared_reference, $child_reference);
$shared_reference = [];
scope {
	my $out = chan;
	local $array[0] = $shared_reference;
	local $hash{name} = $shared_reference;
	act { $out->send([$array[0], $hash{name}]) };
	$child_reference = $out->recv;
};
is_deeply($child_reference, [$shared_reference, $shared_reference], 'element inheritance copies bindings shallowly');
is($child_reference->[0], $shared_reference, 'array element snapshots preserve referent identity');
is($child_reference->[1], $shared_reference, 'hash element snapshots preserve referent identity');

my $inherit_error;
scope {
	local $hash{tied_element};
	tie $hash{tied_element}, 'ElementTied';
	eval { act {} };
	$inherit_error = $@;
};
like($inherit_error, qr/magic variable localization/, 'spawn rejects a binding made magical after element localization');
is($fetches, 0, 'element snapshot validation does not invoke tied FETCH');
check_program(q{
	use Wump;
	our (%hash, @array);
	package ElementOwned { sub DESTROY { print "released\n" } }
	my $park = chan;
	act { local $hash{owned} = bless {}, 'ElementOwned'; local $array[10] = 'parked'; $park->recv };
	yield;
}, 0, qr/\Areleased\n\z/, 'shutdown releases abandoned element bindings');
check_program(q{
	use Wump;
	our %hash;
	package ElementOwned { sub DESTROY { print "released\n" } }
	local $hash{owned} = bless {}, 'ElementOwned';
	act { die 'queued task must not run' };
}, 0, qr/\Areleased\n\z/, 'unstarted child releases inherited element values');

scope { local $hash{name} = 'recovered'; yield; push @seen, $hash{name} };
is($seen[-1], 'recovered', 'later scopes remain usable after failure');
splice @array, 0, 1, 'root splice';
push @array, 'root push';
delete $hash{name};
$hash{new_root} = 1;
is_deeply(\@array, ['root splice', 'new shared', 'root push'], 'retired overlay markers preserve ordinary root array operations');
is_deeply(\%hash, {shared => 'new shared', new_root => 1}, 'retired overlay markers preserve ordinary root hash operations');
done_testing;
