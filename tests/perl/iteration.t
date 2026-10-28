use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'weaken';
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

sub drain ($hash) {
	my @keys;
	for (1 .. 1000) {
		my $key = each %$hash;
		return \@keys unless defined $key;
		push @keys, $key;
	}
	die "hash iteration did not finish\n";
}

my %shared = (map { ("key$_" => $_) } 0 .. 63);
$shared{''} = 64;
$shared{"nul\0key"} = 65;
$shared{"\x{20ac}"} = 66;
RootFixture::scalar_publish(\%shared);
my @expected = sort keys %shared;
my $first = each %shared;
my $ready = chan;
act { my @keys = keys %shared; $ready->send(scalar @keys) };
is($ready->recv, scalar @expected, 'a child can list the shared hash');
is_deeply([sort $first, @{drain(\%shared)}], \@expected, 'child keys do not reset the parent iterator');

my $results = chan;
for (1 .. 2) {
	act {
		keys %shared;
		my @keys;
		for (1 .. @expected + 2) {
			my $key = each %shared;
			last unless defined $key;
			push @keys, $key;
			yield;
		}
		$results->send(\@keys);
	};
}
for (1 .. 8) {
	is_deeply([sort keys %shared], \@expected, 'main keys remain independent during child each');
	is(scalar(() = values %shared), scalar @expected, 'main values remain independent during child each');
	yield;
}
for (1 .. 2) {
	is_deeply([sort @{$results->recv}], \@expected, 'each act visits every key once across yields');
}

for my $reset ('scalar keys', 'void keys', 'list keys', 'values') {
	keys %shared;
	my $start = each %shared;
	if ($reset eq 'scalar keys') { my $count = keys %shared }
	elsif ($reset eq 'void keys') { keys %shared }
	elsif ($reset eq 'list keys') { my @keys = keys %shared }
	else { my @values = values %shared }
	is(each(%shared), $start, "$reset resets this act's iterator");
}
keys %shared;
is_deeply([sort @{drain(\%shared)}], \@expected, 'iteration exhausts completely');
is_deeply([sort @{drain(\%shared)}], \@expected, 'each restarts after exhaustion');

my %empty;
RootFixture::scalar_publish(\%empty);
is(scalar(keys %empty), 0, 'empty published hash has no keys');
ok(!defined each(%empty), 'empty each terminates');

my %deleted = map { ("entry$_" => $_) } 1 .. 12;
RootFixture::scalar_publish(\%deleted);
my @order = keys %deleted;
is(each(%deleted), $order[0], 'each follows the hash bucket order');
delete $deleted{$order[0]};
delete $deleted{$order[1]};
is_deeply([sort @{drain(\%deleted)}], [sort @order[2 .. $#order]], 'deleting current and upcoming keys preserves remaining traversal');
each %deleted;
%deleted = ();
is_deeply(drain(\%deleted), [], 'clearing a hash terminates its active iterator');

my %upcoming = map { ("entry$_" => $_) } 1 .. 12;
RootFixture::scalar_publish(\%upcoming);
my @upcoming_order = keys %upcoming;
each %upcoming;
delete $upcoming{$upcoming_order[-1]};
is_deeply([sort @{drain(\%upcoming)}], [sort @upcoming_order[1 .. $#upcoming_order - 1]], 'deleting an upcoming key does not repeat visited keys');

my %transition = (a => 1, b => 2, c => 3);
my $before_publish = each %transition;
RootFixture::scalar_publish(\%transition);
is_deeply([sort $before_publish, @{drain(\%transition)}], [qw(a b c)], 'publication preserves the publishing act iterator progress');

my %overlaid = (a => 1, b => 2, c => 3);
RootFixture::scalar_publish(\%overlaid);
each %overlaid;
{
	local $overlaid{b} = 20;
	is_deeply([sort @{drain(\%overlaid)}], [qw(a b c)], 'an element binding starts a fresh private view');
	is_deeply([sort keys %overlaid], [qw(a b c)], 'an element overlay replaces an existing plain cursor');
	is_deeply([sort { $a <=> $b } values %overlaid], [1, 3, 20], 'overlay iteration uses the localized values');
}
is_deeply([sort keys %overlaid], [qw(a b c)], 'leaving an overlay restores ordinary hash iteration');

my %aliases = (a => 1, b => 2, c => 3);
RootFixture::scalar_publish(\%aliases);
$_ *= 2 for values %aliases;
is_deeply(\%aliases, {a => 2, b => 4, c => 6}, 'values retain aliases to the original value cells');

{
	package IterationObject;
	our @destroyed;
	sub DESTROY ($self) { push @destroyed, $self->{key} }
}
{
	my %objects = map { ($_ => bless {key => $_}, 'IterationObject') } qw(a b c);
	RootFixture::scalar_publish(\%objects);
	my @order = keys %objects;
	each %objects;
	delete $objects{$order[1]};
	is_deeply(\@IterationObject::destroyed, [$order[1]], 'iteration does not retain deleted upcoming values');
	drain(\%objects);
}

{
	local @IterationObject::destroyed;
	my %objects = map { ($_ => bless {key => $_}, 'IterationObject') } qw(a b c);
	my $current = each %objects;
	delete $objects{$current};
	is_deeply(\@IterationObject::destroyed, [$current], 'deleting a current entry releases its value before publication');
	RootFixture::scalar_publish(\%objects);
	is_deeply(\@IterationObject::destroyed, [$current], 'publication preserves deletion cleanup without another destructor call');
	each %objects;
	is_deeply(\@IterationObject::destroyed, [$current], 'the migrated iterator advances past a previously deleted current entry');
}

my $owner = {a => 1, b => 2};
RootFixture::scalar_publish($owner);
my $weak = $owner;
weaken($weak);
each %$owner;
undef $owner;
ok(defined $weak, 'a partial iterator pins its hash');
if (defined $weak) { keys %$weak }
ok(!defined $weak, 'reset releases the pin after the current operation');

{
	package IterationTie;
	sub TIEHASH { bless {}, shift }
	sub FIRSTKEY { Wump::yield(); 'tied' }
	sub NEXTKEY { undef }
	sub FETCH { 42 }
}
tie my %tied, 'IterationTie';
RootFixture::scalar_publish(\%tied);
is_deeply([keys %tied], ['tied'], 'tied hashes retain their yielding iteration hooks');
is_deeply([values %tied], [42], 'tied values retain FETCH behavior');

WumpTest::check_program(q{
	use Wump; use RootFixture;
	my $hash = {a => 1, b => 2};
	my $ready = chan;
	my $park = chan;
	act { each %$hash; $ready->send(1); $park->recv };
	$ready->recv;
	print "iterator parked\n";
}, 0, qr/\Aiterator parked\n\z/, 'abandoned acts release partial iterator state');
done_testing;
