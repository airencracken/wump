use v5.42;
use strict;
use warnings;
use Test::More;
use English '-no_match_vars';
use Wump;

sub records ($text) {
	open my $fh, '<', \$text or die "scalar input: $!";
	my @records = <$fh>;
	close $fh;
	return \@records;
}
sub output ($field, $record, $label) {
	local $, = $field;
	local $\ = $record;
	my $text = '';
	open my $fh, '>', \$text or die "scalar output: $!";
	yield;
	print {$fh} $label, 'tail';
	close $fh;
	return [$label, $,, $\, $text];
}

my @inputs;
run {
	my $out = chan;
	for my $case ([1, ':', 'a:b:'], [2, '|', 'c|d|']) {
		act {
			local $/ = $case->[1];
			yield;
			my $lines = records($case->[2]);
			chomp @$lines;
			$out->send([$case->[0], $/, $lines]);
		};
	}
	push @inputs, scalar $out->recv for 1..2;
};
is_deeply([sort {$a->[0] <=> $b->[0]} @inputs], [[1, ':', ['a', 'b']], [2, '|', ['c', 'd']]],
	'readline and chomp use independent input separator caches across yields');
is($/, "\n", 'input localization leaves the global separator intact');

my @outputs;
run {
	my $out = chan;
	act { $out->send(output(':', '<a>', 'alpha')) };
	act { $out->send(output('|', '<b>', 'bravo')) };
	push @outputs, scalar $out->recv for 1..2;
};
is_deeply([sort {$a->[0] cmp $b->[0]} @outputs], [
	['alpha', ':', '<a>', 'alpha:tail<a>'], ['bravo', '|', '<b>', 'bravo|tail<b>'],
], 'print observes each task field and record separator after a yield');
is($\, undef, 'output localization leaves the global separator intact');
is($,, undef, 'field separator global slot remains intact');

my (@scope, $error);
run {
	local $/ = ':';
	local $\ = 'outer';
	eval {
		local $/ = '|';
		local $\ = 'inner';
		yield;
		push @scope, [$/, $\, records('x|y|')];
		die "separator unwind\n";
	};
	$error = $@;
	push @scope, [$/, $\, records('x:y:')];
};
is_deeply(\@scope, [['|', 'inner', ['x|', 'y|']], [':', 'outer', ['x:', 'y:']]], 'exception unwinding restores outer values and operation caches together');
is($error, "separator unwind\n", 'separator scope preserves the caught exception');

my ($child, $parent);
run {
	my $go = chan;
	my $out = chan;
	{
		local $/ = ':';
		local $\ = 'inherited';
		pocket $/ = '|';
		pocket $\ = 'private';
		act { $go->recv; $out->send([$/, $\, records('a:b:')]) };
		$parent = [$/, $\, records('a|b|')];
	}
	$go->send(1);
	$child = $out->recv;
};
is_deeply($parent, ['|', 'private', ['a|', 'b|']], 'pocket uses a private input and output cache');
is_deeply($child, [':', 'inherited', ['a:', 'b:']], 'spawn snapshots outer ordinary settings through pocket and parent scope exit');

my @modes;
run {
	{ local $/; push @modes, [$/, records("a\nb\n")] }
	{ local $/ = ''; push @modes, [$/, records("a\n\nb\n\n")] }
	{ my $size = 3; local $/ = \$size; yield; push @modes, [${$/}, records('abcdefg')] }
};
is_deeply($modes[0], [undef, ["a\nb\n"]], 'uninitialized local input separator enables slurp mode');
is_deeply($modes[1], ['', ["a\n\n", "b\n\n"]], 'empty input separator preserves paragraph mode');
is_deeply($modes[2], [3, ['abc', 'def', 'g']], 'scalar-reference input separators preserve fixed-length records');

my ($unicode, $unlocalized);
my $unicode_text = "a\x{3a9}b\x{3a9}";
utf8::encode($unicode_text);
# Initialize this layer before the run; hooks.t also exercises loading inside.
open my $unicode_fh, '<:encoding(UTF-8)', \$unicode_text or die "encoded input: $!";
run {
	{
		local $/ = "\x{3a9}";
		yield;
		my @records = <$unicode_fh>;
		chomp @records;
		$unicode = [$/, \@records];
	}
	$/ = ':';
	my $out = chan;
	act { $out->send([$/, records('a:b:')]) };
	$unlocalized = $out->recv;
};
close $unicode_fh;
is_deeply($unicode, ["\x{3a9}", ['a', 'b']], 'Unicode input separators retain encoding flags in the private cache');
is_deeply($unlocalized, [':', ['a:', 'b:']], 'unlocalized assignments remain shared with other acts');
$/ = "\n";

my @invalid;
run {
	local $/ = ':';
	for my $value (\0, \-1, [], {}) {
		eval { $/ = $value };
		push @invalid, [$@, $/, records('a:b:')];
	}
};
for my $case (@invalid) {
	like($case->[0], qr/Setting \$\/ to .* is forbidden/, 'invalid record separator reference is rejected');
	is_deeply([@$case[1, 2]], [':', ['a:', 'b:']], 'failed assignment preserves the previous setting and cache');
}

my $english;
run {
	local $INPUT_RECORD_SEPARATOR = ':';
	local $OUTPUT_RECORD_SEPARATOR = 'english';
	yield;
	$english = [$/, $\, records('a:b:')];
};
is_deeply($english, [':', 'english', ['a:', 'b:']], 'English aliases address the same task separator bindings');

my ($root_ref, $escaped_input, $escaped_output, $local_after_root_write);
$root_ref = \$/;
run {
	local $/ = '|';
	local $\ = 'private';
	($escaped_input, $escaped_output) = (\$/, \$\);
	$$root_ref = ':';
	$local_after_root_write = [$/, records('a|b|')];
};
is_deeply($local_after_root_write, ['|', ['a|', 'b|']], 'a reference to the base setting cannot replace an active local cache');
is_deeply([$/, records('a:b:')], [':', ['a:', 'b:']], 'base-reference writes remain global after the local binding ends');
$/ = "\n";
is_deeply([$$escaped_input, $$escaped_output], ['|', 'private'], 'escaped separator references retain their own private setting cells');
$$escaped_input = '.';
$$escaped_output = 'changed private';
is_deeply([$$escaped_input, $$escaped_output, $/, $\], ['.', 'changed private', "\n", undef], 'escaped cache mutations leave root settings intact');

my (@tied_seen, $tied_child);
{
	package YieldPrinter;
	sub TIEHANDLE { bless {seen => $_[1]}, $_[0] }
	sub PRINT {
		my $self = shift;
		push @{$self->{seen}}, $\;
		Wump::yield();
		push @{$self->{seen}}, $\;
		my $out = $self->{out};
		Wump::act(sub { $out->send($\) });
		return 1;
	}
}
tie *YIELD_PRINT, 'YieldPrinter', \@tied_seen;
run {
	my $out = chan;
	(tied *YIELD_PRINT)->{out} = $out;
	local $\ = 'ordinary output';
	say {\*YIELD_PRINT} 'text';
	$tied_child = $out->recv;
};
untie *YIELD_PRINT;
is_deeply(\@tied_seen, ["\n", "\n"], 'tied say sees its temporary separator across a yield');
is($tied_child, 'ordinary output', 'internal say override is excluded from child inheritance');
is($\, undef, 'tied say restores the root output separator');

my $abandoned = 0;
{
	package SeparatorOwned;
	sub DESTROY { $abandoned++ }
}
run {
	my $park = chan;
	act {
		my $length = 3;
		local $/ = bless \$length, 'SeparatorOwned';
		$park->recv;
	};
	yield;
};
is($abandoned, 1, 'abandoning a task releases the referenced record-length cache');
run {
	my $length = 3;
	local $/ = bless \$length, 'SeparatorOwned';
	act { die 'queued act must not run' };
};
is($abandoned, 2, 'unstarted children release inherited separator caches');
is($/, "\n", 'shutdown leaves the root input separator intact');

my $later;
run { local $/ = '|'; yield; $later = records('later|works|') };
is_deeply($later, ['later|', 'works|'], 'later runs remain usable after failures, escaped references and tied callbacks');
done_testing;
