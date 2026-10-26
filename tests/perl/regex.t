use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

sub together ($code, @inputs) {
	my @out;
	run {
		my $ch = chan;
		for my $input (@inputs) {
			act { $ch->send($code->(@$input)) };
		}
		push @out, scalar $ch->recv for @inputs;
	};
	return [sort { $a->[0] <=> $b->[0] } @out];
}

sub literal ($id, $text) {
	$text =~ /(?<word>[A-Za-z]+)-(\d+)/;
	yield;
	return [$id, $1, $2, $+{word}, [@-], [@+], $^N];
}
is_deeply(together(\&literal, [1, 'alpha-11'], [2, 'bravo-22']), [
	[1, 'alpha', '11', 'alpha', [0, 0, 6], [8, 5, 8], '11'],
	[2, 'bravo', '22', 'bravo', [0, 0, 6], [8, 5, 8], '22'],
], 'one literal PMOP preserves numbered/named captures and offsets per task');

sub preserved ($id, $text) {
	$text =~ /\[(?<word>\p{L}+)\]/p;
	yield;
	return [$id, ${^MATCH}, ${^PREMATCH}, ${^POSTMATCH}, $1];
}
is_deeply(together(\&preserved, [1, "pre[\x{e9}t\x{e9}]post"], [2, 'x[bravo]y']), [
	[1, "[\x{e9}t\x{e9}]", 'pre', 'post', "\x{e9}t\x{e9}"],
	[2, '[bravo]', 'x', 'y', 'bravo'],
], 'UTF-8 and /p preserve each task match and surrounding text');

sub dynamic ($id, $pattern, $text) {
	$text =~ /($pattern)/;
	yield;
	return [$id, $1];
}
is_deeply(together(\&dynamic, [1, 'alpha', 'alpha'], [2, 'bravo', 'bravo']),
	[[1, 'alpha'], [2, 'bravo']], 'runtime pattern replacement does not overwrite a parked task');

sub once ($id, $pattern, $text, $park) {
	$text =~ /($pattern)/o;
	yield if $park;
	return [$id, $1];
}
is_deeply(once(0, 'root', 'root', 0), [0, 'root'], 'prime /o cache outside the runtime');
is_deeply(together(\&once, [1, 'alpha', 'alpha', 1], [2, 'bravo', 'bravo', 1]),
	[[1, 'alpha'], [2, 'bravo']], 'each task has its own /o cache despite a primed root pattern');
is_deeply(once(0, 'ignored', 'root', 0), [0, 'root'], 'task compilation leaves the root /o cache intact');

my $qr = qr/(?<word>[A-Za-z]+)-(\d+)/;
sub shared_qr ($id, $text) {
	$text =~ $qr;
	yield;
	return [$id, $1, $2, $+{word}];
}
is_deeply(together(\&shared_qr, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'alpha', '11', 'alpha'], [2, 'bravo', '22', 'bravo']], 'a shared qr value still produces separate match state');

sub empty_again ($id, $text) {
	$text =~ /([A-Za-z]+)-\d+/;
	yield;
	my $ok = $text =~ //;
	return [$id, !!$ok, $1];
}
is_deeply(together(\&empty_again, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 1, 'alpha'], [2, 1, 'bravo']], 'an empty literal pattern reuses the task previous pattern');

sub empty_subst ($id, $text) {
	$text =~ /[A-Za-z]+/;
	yield;
	$text =~ s//changed/;
	return [$id, $text];
}
is_deeply(together(\&empty_subst, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'changed-11'], [2, 'changed-22']], 'empty substitution retains ordinary previous-pattern semantics');

sub once_match ($id) {
	my $text = 'abc';
	my @matched;
	for (1..2) {
		push @matched, !!($text =~ m?(a)?);
		yield;
	}
	return [$id, @matched];
}
is_deeply(together(\&once_match, [1], [2]),
	[[1, 1, ''], [2, 1, '']], 'match-once flags belong to each task');

{
	package WumpTest::TiedText;
	sub TIESCALAR ($class, $text, $count) { bless {text => $text, count => $count}, $class }
	sub FETCH ($self) { ${$self->{count}}++; return $self->{text} }
}
sub magical ($id, $text) {
	my $fetches = 0;
	tie my $value, 'WumpTest::TiedText', $text, \$fetches;
	my $matched = $value =~ /([A-Za-z]+)-\d+/;
	yield;
	return [$id, !!$matched, $1, $fetches];
}
is_deeply(together(\&magical, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 1, 'alpha', 1], [2, 1, 'bravo', 1]], 'copying a literal regex does not skip or repeat tied FETCH');

sub global_matches ($id, $text) {
	my @out;
	while ($text =~ /([A-Za-z]+)(\d+)/g) {
		yield;
		push @out, [$1, $2, pos($text)];
	}
	return [$id, \@out];
}
is_deeply(together(\&global_matches, [1, 'a1 b2'], [2, 'c3 d4']), [
	[1, [['a', '1', 2], ['b', '2', 5]]],
	[2, [['c', '3', 2], ['d', '4', 5]]],
], 'global matches preserve captures and scalar pos between yields');

# Use one op for both attempts; distinct m?? expressions have distinct flags.
sub one_op ($text) { return !!($text =~ m?(a)?) }
sub reset_one_op ($id) {
	my $first = one_op('abc');
	yield;
	reset if $id == 1;
	yield;
	return [$id, $first, one_op('abc')];
}
is_deeply(together(\&reset_one_op, [1], [2]),
	[[1, 1, 1], [2, 1, '']], 'reset clears only the calling task match-once state');

sub failed_match ($id, $text) {
	$text =~ /([A-Za-z]+)-(\d+)/;
	yield;
	my $ok = $text =~ /(this-pattern-does-not-match)/;
	return [$id, !!$ok, $1, $2];
}
is_deeply(together(\&failed_match, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, '', 'alpha', '11'], [2, '', 'bravo', '22']], 'a failed match preserves the task last successful captures');

sub invalid_pattern ($id, $text) {
	$text =~ /([A-Za-z]+)-(\d+)/;
	my $bad = '[';
	eval { $text =~ /$bad/ };
	my $error = $@;
	yield;
	my ($first, $second) = ($1, $2);
	return [$id, $first, $second, !!($error =~ /Unmatched|Unterminated/)];
}
is_deeply(together(\&invalid_pattern, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'alpha', '11', 1], [2, 'bravo', '22', 1]], 'invalid compilation unwinds without overwriting another task captures');

sub callback ($id, $text) {
	$text =~ /([A-Za-z]+)-(?{ yield; $id })(\d+)/;
	yield;
	return [$id, $1, $2, $^R];
}
is_deeply(together(\&callback, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'alpha', '11', 1], [2, 'bravo', '22', 2]], 'regex code blocks yield with private engine frames and $^R');

my $code_qr = qr/([A-Za-z]+)-(?{
	my $remembered = $1;
	sleep 0.0001;
	$remembered;
})(\d+)/;
sub external_code ($id, $text) {
	$text =~ $code_qr;
	yield;
	return [$id, $1, $2, $^R];
}
is_deeply(together(\&external_code, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'alpha', '11', 'alpha'], [2, 'bravo', '22', 'bravo']], 'a shared qr code block has task-specific local pads and results');

my ($long_entered, $long_release, $fast_entered, $fast_release);
my $overlap_qr = qr/([a-z]+)(?{
	my $saved = $1;
	if ($saved eq 'long') {
		$long_entered->send(1);
		$long_release->recv;
	} elsif ($saved ne 'short') {
		$fast_entered->send(1);
		$fast_release->recv;
	} else {
		yield;
	}
	$saved;
})/;
sub overlap_code ($text) { $text =~ $overlap_qr; return [$text, $^R] }
my @overlap;
run {
	my $ch = chan;
	$long_entered = chan;
	$long_release = chan;
	$fast_entered = chan;
	$fast_release = chan;
	act { $ch->send(overlap_code('short')) };
	act { $ch->send(overlap_code('long')) };
	$long_entered->recv;
	push @overlap, scalar $ch->recv;
	act { $ch->send(overlap_code('fasta')) };
	act { $ch->send(overlap_code('fastb')) };
	$fast_entered->recv for 1..2;
	$long_release->send(1);
	push @overlap, scalar $ch->recv;
	$fast_release->send(1) for 1..2;
	push @overlap, scalar $ch->recv for 1..2;
};
is_deeply([sort { $a->[0] cmp $b->[0] } @overlap],
	[map { [$_, $_] } qw(fasta fastb long short)], 'out-of-order regex callbacks retain their own lexical pads');

sub backtrack ($id, $text) {
	my $ok = $text =~ /^(?<part>[ab]+)(?{ yield })b$/;
	return [$id, !!$ok, $1, $+{part}];
}
is_deeply(together(\&backtrack, [1, 'aaabb'], [2, 'bbbb']),
	[[1, 1, 'aaab', 'aaab'], [2, 1, 'bbb', 'bbb']], 'backtracking resumes with the task own capture state');

sub replace ($id, $text) {
	$text =~ s/([A-Za-z]+)-(\d+)/yield; "$1:$2"/e;
	return [$id, $text, $1, $2];
}
is_deeply(together(\&replace, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'alpha:11', 'alpha', '11'], [2, 'bravo:22', 'bravo', '22']], 'substitution replacement code can yield with its own captures');

sub named_iteration ($id) {
	'abc' =~ /(?<a>a)(?<b>b)(?<c>c)/;
	my @found;
	while (my ($key, $value) = each %+) {
		push @found, "$key=$value";
		last if @found > 6;
		yield;
	}
	return [$id, [sort @found]];
}
is_deeply(together(\&named_iteration, [1], [2]),
	[[1, ['a=a', 'b=b', 'c=c']], [2, ['a=a', 'b=b', 'c=c']]], 'named capture iterators do not consume another task keys');

our %named_alias;
{
	no warnings 'once';
	*named_alias = *+;
}
sub named_alias_iteration ($id) {
	'abc' =~ /(?<a>a)(?<b>b)(?<c>c)/;
	my @found;
	while (my ($key, $value) = each %named_alias) {
		push @found, "$key=$value";
		last if @found > 6;
		yield;
	}
	return [$id, [sort @found]];
}
is_deeply(together(\&named_alias_iteration, [1], [2]),
	[[1, ['a=a', 'b=b', 'c=c']], [2, ['a=a', 'b=b', 'c=c']]], 'glob aliases keep the task-local named capture view');

sub duplicate_names ($id, $text) {
	$text =~ /(?<letter>[a-z])(?<letter>[a-z])/;
	yield;
	my %all = %-;
	return [$id, $+{letter}, $all{letter}, ${^CAPTURE}{letter}, ${^CAPTURE_ALL}{letter}];
}
is_deeply(together(\&duplicate_names, [1, 'ab'], [2, 'cd']),
	[[1, 'a', ['a', 'b'], 'a', ['a', 'b']], [2, 'c', ['c', 'd'], 'c', ['c', 'd']]],
	'duplicate names and long-form capture hashes use the task match');

my @root_keys;
'abc' =~ /(?<a>a)(?<b>b)(?<c>c)/;
while (my ($key, $value) = each %+) {
	push @root_keys, "$key=$value";
	together(\&named_iteration, [1], [2]);
	last if @root_keys > 6;
}
is_deeply([sort @root_keys], ['a=a', 'b=b', 'c=c'], 'task runs leave the root named capture iterator intact');

sub reused_ops ($id) {
	my @seen;
	for my $number (1..30) {
		my $word = "task${id}value${number}";
		my $compiled = eval 'qr/(?<word>' . $word . ')/';
		die $@ if $@;
		$word =~ $compiled;
		yield;
		push @seen, $+{word};
	}
	return [$id, \@seen];
}
is_deeply(together(\&reused_ops, [1], [2]), [
	[1, [map { "task1value$_" } 1..30]],
	[2, [map { "task2value$_" } 1..30]],
], 'freed and reused regex slots cannot retrieve stale task instances');

my ($escaped, $escaped_code);
run {
	$escaped = eval 'qr/(?<word>escaped)-(\d+)/';
	die $@ if $@;
	my $message = 'closure survived';
	$escaped_code = qr/(?<word>escaped)(?{ $message })/;
};
'escaped-99' =~ $escaped;
is_deeply([$1, $2, $+{word}], ['escaped', '99', 'escaped'], 'a qr value remains valid after its creating task ends');
'escaped' =~ $escaped_code;
is($^R, 'closure survived', 'escaped regex code retains captured lexicals after task cleanup');

my $transferred;
run {
	my $ch = chan;
	act {
		my $owned_text = 'producer closure';
		$ch->send(qr/(?<word>message)(?{ $owned_text })/);
	};
	my $compiled = $ch->recv;
	yield;
	'message' =~ $compiled;
	$transferred = [$+{word}, $^R];
};
is_deeply($transferred, ['message', 'producer closure'], 'regex code sent through a channel survives producer cleanup');

my ($entered, $completed) = (0, 0);
run {
	my $wait = chan;
	act {
		'parked' =~ /(parked)(?{ $entered++; $wait->recv })/;
		$completed++;
	};
	yield until $entered;
};
is_deeply([$entered, $completed], [1, 0], 'shutdown abandons a task parked inside regex execution');
is_deeply(together(\&callback, [1, 'alpha-11'], [2, 'bravo-22']),
	[[1, 'alpha', '11', 1], [2, 'bravo', '22', 2]], 'regex code recovers after abandoned engine frames');

{
	package WumpTest::RegexDestructor;
	sub new ($class, $results) { bless {results => $results}, $class }
	sub DESTROY ($self) {
		'released' =~ /(?<word>released)(?{ 7 })/;
		push @{$self->{results}}, [$1, $^R, [sort keys %+]];
	}
}
my @destroyed;
run {
	my $ch = chan;
	act {
		state $owned = WumpTest::RegexDestructor->new(\@destroyed);
		$ch->send(1);
	};
	$ch->recv;
	yield;
};
is_deeply(\@destroyed, [['released', 7, ['word']]], 'teardown drains regex caches created by destructors');

done_testing;
