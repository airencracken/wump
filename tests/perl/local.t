use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
use lib 'tests/perl/lib';
use WumpTest;

our ($mode, @items, %options);
$mode = 'global';
@items = ('global');
%options = (global => 1);
my (@seen, @outside);
with_tasks {
	my $out = chan;
	for my $name ('alpha', 'bravo') {
		act {
			local $mode = $name;
			local @items = ($name, undef);
			local %options = (name => $name);
			yield;
			$out->send([$mode, [@items], {%options}]);
		};
	}
	push @seen, scalar $out->recv for 1..2;
	@outside = ($mode, [@items], {%options});
};
is_deeply([sort { $a->[0] cmp $b->[0] } @seen], [
	['alpha', ['alpha', undef], {name => 'alpha'}],
	['bravo', ['bravo', undef], {name => 'bravo'}],
], 'parked tasks keep scalar, array and hash localizations separate');
is_deeply(\@outside, ['global', ['global'], {global => 1}], 'other tasks see the global slots');
is_deeply([$mode, [@items], {%options}], \@outside, 'scope leaves the original global slots intact');

my (@nested, $early);
sub early {
	local $mode = 'return';
	yield;
	return $mode;
}
with_tasks {
	local $mode = 'outer';
	eval {
		local $mode = 'inner';
		yield;
		push @nested, $mode;
		die "scope failure\n";
	};
	push @nested, $mode, $@;
	$early = early();
	push @nested, $mode;
};
is_deeply(\@nested, ['inner', 'outer', "scope failure\n", 'outer'], 'exception unwinds only the innermost binding');
is($early, 'return', 'return from a sub preserves the localized result');
is($mode, 'global', 'early return unwinds the binding');

my $isolated;
with_tasks {
	my $ready = chan;
	my $resume = chan;
	my $out = chan;
	act {
		local $mode = 'private';
		$ready->send(1);
		$resume->recv;
		$out->send($mode);
	};
	$ready->recv;
	$mode = 'new global';
	$resume->send(1);
	$isolated = $out->recv;
};
is($isolated, 'private', 'an unlocalized write cannot replace another task binding');
is($mode, 'new global', 'unwinding a binding does not restore over a newer global write');
$mode = 'global';

my (@family, $parent);
with_tasks {
	my $go = chan;
	my $out = chan;
	{
		local $mode = 'at spawn';
		local @items = ('at spawn');
		local %options = (name => 'at spawn');
		act {
			$go->recv;
			push @family, [$mode, [@items], {%options}];
			$mode = 'child';
			push @items, 'child';
			$options{child} = 1;
			{
				local $mode = 'nested child';
				yield;
			}
			$out->send([$mode, [@items], {%options}]);
		};
		$mode = 'later parent';
		$items[0] = 'later parent';
		$options{name} = 'later parent';
		$parent = [$mode, [@items], {%options}];
	}
	$go->send(1);
	push @family, scalar $out->recv;
};
is_deeply($family[0], ['at spawn', ['at spawn'], {name => 'at spawn'}], 'spawn snapshots survive changes and parent scope exit');
is_deeply($family[1], ['child', ['at spawn', 'child'], {name => 'at spawn', child => 1}], 'child assignments and nested local use its inherited slots');
is_deeply($parent, ['later parent', ['later parent'], {name => 'later parent'}], 'child mutations leave the parent bindings intact');

our ($slots, @slots, %slots);
($slots, @slots) = ('root', 'root');
%slots = (root => 1);
my ($empty_slots, $nested_slots);
with_tasks {
	my $out = chan;
	local $slots;
	local @slots;
	local %slots;
	act { $out->send([$slots, [@slots], {%slots}]) };
	$empty_slots = $out->recv;
	@slots = ('outer');
	%slots = (outer => 1);
	{
		local @slots = ('inner');
		local %slots = (inner => 1);
		yield;
	}
	$nested_slots = [[@slots], {%slots}];
};
is_deeply($empty_slots, [undef, [], {}], 'undef and empty snapshots keep the three slots of one glob separate');
is_deeply($nested_slots, [['outer'], {outer => 1}], 'nested aggregate scopes restore the enclosing bindings');
is_deeply([$slots, [@slots], {%slots}], ['root', ['root'], {root => 1}], 'all three global slots survive localization');

my ($grandchild, @defaults);
with_tasks {
	my $out = chan;
	local $mode = 'ancestor';
	local $_ = 'default at spawn';
	act {
		push @defaults, $_;
		$mode = 'child';
		act { $out->send([$mode, $_]) };
	};
	$grandchild = $out->recv;
};
is_deeply(\@defaults, ['default at spawn'], 'explicitly localized default scalar is inherited');
is_deeply($grandchild, ['child', 'default at spawn'], 'inherited bindings propagate to grandchildren');

our ($alias, @alias, %alias);
BEGIN { *alias = *mode }
my ($alias_seen, $global_ref, $local_ref);
$global_ref = \$mode;
with_tasks {
	local $alias = 'alias';
	$local_ref = \$mode;
	yield;
	$alias_seen = [$alias, $mode, $$global_ref];
};
is_deeply($alias_seen, ['alias', 'alias', 'global'], 'glob aliases share the binding while old references retain the global slot');
is($$local_ref, 'alias', 'a reference keeps a localized scalar alive after scope exit');
isnt($local_ref, $global_ref, 'local creates a distinct scalar identity');

my $referent = [];
my ($identity, $sparse, $hash_copy, $iterator);
with_tasks {
	my $out = chan;
	local $mode = $referent;
	local @items;
	$#items = 5;
	$items[2] = $referent;
	local %options = ("\x{e9}" => $referent, empty => undef);
	my ($key) = each %options;
	act {
		push @$mode, 'shared referent';
		$out->send([$mode, exists $items[0], exists $items[2], $#items,
			$items[2], {%options}]);
	};
	my $value = $out->recv;
	($identity, $sparse, $hash_copy) = ($value->[0], [@$value[1..4]], $value->[5]);
	my @remaining;
	while (my ($next) = each %options) { push @remaining, $next }
	$iterator = [$key, @remaining];
};
is($identity, $referent, 'scalar inheritance preserves reference identity');
is_deeply($referent, ['shared referent'], 'spawn copies bindings shallowly');
is_deeply($sparse, ['', 1, 5, $referent], 'array snapshots preserve holes, length, and reference identity');
is_deeply($hash_copy, {"\x{e9}" => $referent, empty => undef}, 'hash snapshots preserve Unicode keys, undef and reference identity');
is_deeply([sort @$iterator], [sort ("\x{e9}", 'empty')], 'snapshot does not disturb the parent hash iterator');

my @destructed;
{
	package LocalCleanup;
	sub DESTROY {
		push @destructed, $main::mode;
		Wump::yield();
		Wump::act(sub { push @destructed, $main::mode });
	}
}
with_tasks {
	local $mode = 'enclosing';
	{
		local $mode = bless {}, 'LocalCleanup';
	}
	yield;
};
is_deeply(\@destructed, ['enclosing', 'enclosing'], 'completing scope-exit destructor can yield and spawn after the old binding is detached');

check_program(q{
	use Wump;
	our $mode;
	package LocalOwned { sub DESTROY { print "released\n" } }
	my $park = chan;
	act { local $mode = bless {}, 'LocalOwned'; $park->recv };
	yield;
}, 0, qr/\Areleased\n\z/, 'shutdown unwinds a parked localization');
check_program(q{
	use Wump;
	our $mode;
	package LocalOwned { sub DESTROY { print "released\n" } }
	local $mode = bless {}, 'LocalOwned';
	act { die 'queued task should not start' };
}, 0, qr/\Areleased\n\z/, 'unstarted child releases inherited references');

my @errors;
our (@guard_array, %guard_hash);
@guard_array = ('root');
%guard_hash = (root => 1);
my @forms = (
	sub { delete local $guard_hash{root} },
	sub { local *guard_array },
	sub { local $^I = '.backup' },
	sub { local %ENV },
);
with_tasks {
	for my $form (@forms) {
		eval { $form->() };
		push @errors, $@;
	}
};
like($_, qr/Wump: .*localization in a task is not supported yet/, 'unsupported local form fails explicitly') for @errors;
is_deeply(\@guard_array, ['root'], 'rejected forms leave the global array intact');
is_deeply(\%guard_hash, {root => 1}, 'rejected forms leave the global hash intact');
is($^I, undef, 'rejected magic localization leaves the interpreter value intact');

my ($tied_error, $fetches) = ('', 0);
{
	package LocalTied;
	sub TIESCALAR { bless {}, shift }
	sub FETCH { $fetches++; return 'tied' }
}
with_tasks {
	local @items = ('plain');
	tie $items[0], 'LocalTied';
	eval { act {} };
	$tied_error = $@;
};
like($tied_error, qr/magic variable localization/, 'spawn rejects magic inside an inherited binding');
is($fetches, 0, 'snapshot validation does not run tied FETCH');

with_tasks { local $mode = 'healthy'; yield; push @seen, $mode };
is($seen[-1], 'healthy', 'later scopes remain usable after all failure paths');
{
	local $mode = 'ordinary root scope';
	local $guard_hash{root} = 2;
	is($guard_hash{root}, 2, 'root-context element localization retains stock Perl behavior');
}
is($mode, 'global', 'root-context scalar localization retains stock Perl behavior');
done_testing;
