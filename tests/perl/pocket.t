use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;

our ($mode, @items, %options, $object);
$mode = 'global';
@items = ('global', 'shared');
%options = (name => 'global', shared => 1);
sub read_mode { $mode }
my ($inside, $called, $child, $restored);
run {
	my $out = chan;
	{
		pocket $mode = 'private';
		yield;
		$inside = $mode;
		$called = read_mode();
		act { $out->send($mode) };
		$child = $out->recv;
	}
	$restored = $mode;
};
is($inside, 'private', 'pocket is a native declaration that survives a yield');
is($called, 'private', 'a function defined elsewhere sees the current act dynamic binding');
is($child, 'global', 'a spawned act does not inherit a pocket binding');
is($restored, 'global', 'pocket ends at the enclosing block boundary');
is($mode, 'global', 'pocket leaves the original global scalar intact');

my (@siblings, $grandchild);
run {
	my $out = chan;
	for my $name ('alpha', 'bravo') {
		act { pocket $mode = $name; yield; $out->send([$name, read_mode()]) };
	}
	push @siblings, scalar $out->recv for 1..2;
};
is_deeply([sort {$a->[0] cmp $b->[0]} @siblings], [['alpha', 'alpha'], ['bravo', 'bravo']], 'sibling acts retain independent pockets across scheduling');
is($mode, 'global', 'sibling pockets leave the root binding intact');
run {
	my $out = chan;
	local $mode = 'ordinary ancestor';
	pocket $mode = 'parent private';
	act {
		pocket $mode = 'child private';
		act { $out->send($mode) };
	};
	$grandchild = $out->recv;
};
is($grandchild, 'ordinary ancestor', 'grandchildren skip each act pocket while retaining the inherited ordinary binding');

my (@seen, @nested);
run {
	my $out = chan;
	local $mode = 'ordinary';
	local @items = ('ordinary');
	local %options = (name => 'ordinary');
	{
		pocket ($mode, @items) = ('private', 'private item');
		pocket %options = (name => 'private');
		act { $out->send([$mode, [@items], {%options}]) };
		push @seen, scalar $out->recv;
		{
			pocket $mode = 'more private';
			act { $out->send([$mode, [@items], {%options}]) };
			push @seen, scalar $out->recv;
		}
		{
			local $mode = 'explicit';
			act { $out->send([$mode, [@items], {%options}]) };
			push @seen, scalar $out->recv;
		}
		push @nested, $mode;
	}
	push @nested, $mode, [@items], {%options};
};
is_deeply($seen[0], ['ordinary', ['ordinary'], {name => 'ordinary'}], 'child skips pockets to the enclosing ordinary bindings of each kind');
is_deeply($seen[1], $seen[0], 'multiple nested pockets do not hide the inheritable baseline');
is_deeply($seen[2], ['explicit', ['ordinary'], {name => 'ordinary'}], 'ordinary local inside pocket opts its binding into inheritance');
is_deeply(\@nested, ['private', 'ordinary', ['ordinary'], {name => 'ordinary'}], 'nested scopes restore the expected scalar and aggregate bindings');

my ($snapshot, $parent_after);
run {
	my $out = chan;
	local $mode = 'at spawn';
	my $outer = \$mode;
	pocket $mode = 'private';
	act { $out->send($mode) };
	$$outer = 'later ordinary';
	$snapshot = $out->recv;
	$parent_after = $mode;
};
is($snapshot, 'at spawn', 'child snapshots the eligible outer value at spawn time');
is($parent_after, 'private', 'writing through an outer reference does not replace the pocket binding');

my (@element_children, $element_parent);
run {
	my $out = chan;
	local $items[0] = 'ordinary element';
	local $options{name} = 'ordinary element';
	pocket @items[0, 8] = ('private element', 'private extent');
	pocket @options{'name', 'extra'} = ('private element', 'private key');
	$element_parent = [$items[0], $#items, $options{name}, exists $options{extra}];
	act { $out->send([[@items], {%options}]) };
	push @element_children, scalar $out->recv;
	{
		local $items[0] = 'explicit element';
		local $options{name} = 'explicit element';
		act { $out->send([[@items], {%options}]) };
		push @element_children, scalar $out->recv;
	}
};
is_deeply($element_parent, ['private element', 8, 'private element', 1], 'array/hash slice pockets define the current act view');
is_deeply($element_children[0], [['ordinary element', 'shared'], {name => 'ordinary element', shared => 1}], 'child element snapshots omit private cells, keys and extent');
is_deeply($element_children[1], [['explicit element', 'shared'], {name => 'explicit element', shared => 1}], 'ordinary element overrides remain inheritable inside a pocket scope');

my ($aggregate_child, $parent_iterator);
run {
	my $out = chan;
	local @items = ('ordinary aggregate', 'shared');
	local %options = (name => 'ordinary aggregate', shared => 1);
	pocket $items[0] = 'private cell';
	pocket $items[9] = 'private extent';
	pocket $options{name} = 'private cell';
	pocket $options{extra} = 'private key';
	my ($first) = each %options;
	act { $out->send([[@items], {%options}]) };
	$aggregate_child = $out->recv;
	my @remaining;
	while (my ($key) = each %options) { push @remaining, $key }
	$parent_iterator = [$first, @remaining];
};
is_deeply($aggregate_child, [['ordinary aggregate', 'shared'], {name => 'ordinary aggregate', shared => 1}], 'whole-container snapshots also exclude pocketed elements');
is_deeply([sort @$parent_iterator], ['extra', 'name', 'shared'], 'inheritance snapshot leaves the parent pocket hash iterator intact');

my ($missing_child, $masked_child);
run {
	my $out = chan;
	pocket $options{name} = 'private';
	delete $options{name};
	pocket $options{extra} = 'private';
	act { $out->send([exists $options{name}, $options{name}, exists $options{extra}]) };
	$missing_child = $out->recv;
	{
		local $options{name} = 'ordinary mask';
		delete $options{name};
		pocket $options{name} = 'private resurrection';
		act { $out->send([exists $options{name}, $options{name}]) };
		$masked_child = $out->recv;
	}
};
is_deeply($missing_child, [1, 'global', ''], 'a pocket deletion mask does not hide a global key from children');
is_deeply($masked_child, ['', undef], 'a pocket resurrection does not expose an ordinary deletion mask to children');

our $alias;
BEGIN { *alias = *mode }
my ($alias_child, $alias_parent, $escaped);
run {
	my $out = chan;
	local $mode = 'ordinary alias';
	pocket $alias = 'private alias';
	$alias_parent = read_mode();
	$escaped = \$mode;
	act { $out->send($mode) };
	$alias_child = $out->recv;
};
is($alias_parent, 'private alias', 'glob aliases address the same pocket binding');
is($alias_child, 'ordinary alias', 'inheritance filtering respects glob aliases');
is($$escaped, 'private alias', 'a reference can keep a pocket scalar alive past block exit');

my ($explicit_reference, $inherited_reference, $private_reference, $ordinary_reference);
run {
	my $out = chan;
	local $object = [];
	my $ordinary = $object;
	$ordinary_reference = $ordinary;
	pocket $object = [];
	my $captured = $object;
	$private_reference = $captured;
	act { push @$captured, 'shared explicitly'; $out->send([$captured, $object]) };
	my $values = $out->recv;
	($explicit_reference, $inherited_reference) = @$values;
};
is($inherited_reference, $ordinary_reference, 'ordinary reference binding retains referent identity across spawn');
is($explicit_reference, $private_reference, 'explicitly captured references retain their ordinary shared identity');
is_deeply($private_reference, ['shared explicitly'], 'pocket controls binding inheritance rather than copying referenced objects');

my ($eval_value, $eval_after, @exception);
run {
	$eval_value = eval 'pocket $mode = "eval pocket"; yield; $mode';
	$eval_after = $mode;
	eval {
		pocket $mode = 'exception pocket';
		yield;
		die "pocket failure\n";
	};
	@exception = ($mode, $@);
};
is($eval_value, 'eval pocket', 'string eval inherits the lexical keyword opt-in');
is($eval_after, 'global', 'eval scope exit releases its pocket binding');
is_deeply(\@exception, ['global', "pocket failure\n"], 'caught exception unwinds pocket through the normal save stack');

my ($index_child, $index_parent);
run {
	my $out = chan;
	pocket $options{do {
		local $mode = 'ordinary index expression';
		act { $out->send($mode) };
		'name';
	}} = 'private indexed value';
	$index_child = $out->recv;
	$index_parent = $options{name};
};
is($index_child, 'ordinary index expression', 'pocket marking does not capture ordinary local inside an index expression');
is($index_parent, 'private indexed value', 'complex index expression still produces a pocket element');

my ($uninitialized, $early, $after_return, $symbolic);
sub early_pocket {
	pocket $mode = 'return pocket';
	yield;
	return $mode;
}
run {
	{
		pocket $mode;
		pocket @items;
		pocket %options;
		$uninitialized = [$mode, [@items], {%options}];
	}
	$early = early_pocket();
	$after_return = $mode;
	{
		no strict 'refs';
		my $name = 'main::mode';
		pocket ${$name} = 'symbolic pocket';
		$symbolic = $mode;
	}
};
is_deeply($uninitialized, [undef, [], {}], 'uninitialized pockets use the same empty values as local');
is($early, 'return pocket', 'early return retains a pocket result across a yield');
is($after_return, 'global', 'early return releases the pocket binding');
is($symbolic, 'symbolic pocket', 'symbolic package targets use the same pocket machinery');

my ($fetches, $private_magic_child, $inheritable_magic_error) = (0, undef, '');
{
	package PocketTied;
	sub TIESCALAR { bless {}, shift }
	sub FETCH { $fetches++; 'private tied value' }
	sub STORE {}
}
run {
	my $out = chan;
	{
		local $mode = 'ordinary';
		pocket $mode = 'private';
		tie $mode, 'PocketTied';
		act { $out->send($mode) };
		$private_magic_child = $out->recv;
	}
	{
		local $mode = 'ordinary';
		my $outer = \$mode;
		pocket $mode = 'private';
		tie $$outer, 'PocketTied';
		eval { act {} };
		$inheritable_magic_error = $@;
	}
};
is($private_magic_child, 'ordinary', 'spawn omits a pocket that was subsequently made magical');
like($inheritable_magic_error, qr/magic variable localization/, 'snapshot validates the inheritable outer binding even while pocket hides it');
is($fetches, 0, 'inheritance filtering and validation do not invoke tied FETCH');

my $private_aggregate_magic;
run {
	my $out = chan;
	local @items = ('ordinary');
	local %options = (name => 'ordinary');
	pocket $items[0] = 'private';
	pocket $options{name} = 'private';
	tie $items[0], 'PocketTied';
	tie $options{name}, 'PocketTied';
	act { $out->send([[@items], {%options}]) };
	$private_aggregate_magic = $out->recv;
};
is_deeply($private_aggregate_magic, [['ordinary'], {name => 'ordinary'}], 'whole-container snapshots omit pocket elements even after those cells become magical');
is($fetches, 0, 'omitting magical pocket elements does not invoke FETCH');

my ($destroyed, $at_parent_exit, $abandoned) = (0, 0, 0);
{
	package PocketOwned;
	sub DESTROY { ${$_[0]->{counter}}++ }
}
run {
	my $out = chan;
	{
		pocket $object = bless {counter => \$destroyed}, 'PocketOwned';
		act { $out->send(1) };
	}
	$at_parent_exit = $destroyed;
	$out->recv;
};
is($at_parent_exit, 1, 'queued children do not retain a pocket object after parent scope exit');
run {
	my $park = chan;
	act {
		pocket $options{owned} = bless {counter => \$abandoned}, 'PocketOwned';
		$park->recv;
	};
	yield;
};
is($abandoned, 1, 'shutdown unwinds an abandoned pocket element');
ok(!exists $options{owned}, 'abandoned pocket elements leave the global aggregate intact');

my @unsupported;
run {
	for my $form (sub { pocket $/ = 'bad' }, sub { pocket *mode }) {
		eval { $form->() };
		push @unsupported, $@;
	}
};
like($unsupported[0], qr/magic variable localization/, 'pocket retains the current magic-variable restriction');
like($unsupported[1], qr/typeglob localization/, 'pocket retains the current typeglob restriction');

my @outside_errors;
for my $form (sub { pocket $mode = 'bad' }, sub { pocket @items = ('bad') },
	sub { pocket %options = (bad => 1) }, sub { pocket $items[50] = 'bad' },
	sub { pocket $options{bad} = 1 }) {
	eval { $form->() };
	push @outside_errors, $@;
}
like($_, qr/pocket requires a running task/, 'executing pocket outside an act fails explicitly') for @outside_errors;
is_deeply([$mode, [@items], {%options}], ['global', ['global', 'shared'], {name => 'global', shared => 1}], 'rejected root-context pockets leave globals intact');
eval 'my $lexical; pocket $lexical = 1';
like($@, qr/Can't localize lexical variable/, 'pocket follows local restrictions on lexical scalar targets');
eval 'pocket ($mode = "bad target")';
like($@, qr/unsupported pocket target/, 'pocket rejects an assignment expression as its declaration target');
eval 'pocket \$mode = \$alias';
like($@, qr/pocket reference alias localization/, 'unsupported reference declarations fail while pocket syntax is compiled');

{
	no Wump;
	sub pocket { 'ordinary sub name' }
	is(pocket(), 'ordinary sub name', 'no Wump restores ordinary lookup of the name pocket');
	my %names = (pocket => 'key');
	is($names{pocket}, 'key', 'ordinary bare hash keys remain available');
}
my $enabled_again;
run { pocket $mode = 'enabled again'; $enabled_again = $mode };
is($enabled_again, 'enabled again', 'keyword opt-in returns after the no Wump lexical scope');

my %keyword_names = (pocket => 'ordinary key');
is($keyword_names{pocket}, 'ordinary key', 'enabled keyword preserves implicit quoting of hash keys');
is(main::pocket(), 'ordinary sub name', 'qualified calls bypass keyword lookup in an enabled scope');
{
	package PocketNames;
	sub pocket { 'ordinary method name' }
}
my $named_object = bless {}, 'PocketNames';
is($named_object->pocket, 'ordinary method name', 'method names retain ordinary lookup in an enabled scope');
require './tests/perl/lib/PocketLegacy.pm';
is(PocketLegacy::call(), 42, 'required code does not inherit the caller keyword opt-in');

done_testing;
