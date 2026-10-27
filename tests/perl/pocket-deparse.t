use v5.42;
use strict;
use warnings;
use Test::More;
use B::Deparse;
use Wump;

our ($mode, @items, %options);
$mode = 'global';
@items = ('global');
%options = (name => 'global');
my $source = sub {
	my $answer;
	scope {
		my $out = chan;
		local $mode = 'ordinary';
		pocket $mode = 'private';
		pocket (@items, %options) = ('private');
		pocket $options{name} = 'private key';
		pocket @items[0, 2] = ('private item', 'private extent');
		act { $out->send([$mode, [@items], {%options}]) };
		$answer = [$mode, scalar $out->recv];
	};
	return $answer;
};
my $text = B::Deparse->new->coderef2text($source);
like($text, qr/\bpocket(?:\s+|\()/, 'deparsed code retains the pocket keyword');
unlike($text, qr/local \$mode = 'private'/, 'deparse does not replace a pocket declaration with ordinary local');
my $copy = eval "use Wump; sub $text";
is($@, '', 'deparsed pocket declarations compile again');
if ($copy) {
	is_deeply($copy->(), ['private', ['ordinary', ['global'], {name => 'global'}]],
		'recompiled code preserves scalar, aggregate, element and slice inheritance');
} else {
	fail('recompiled code preserves scalar, aggregate, element and slice inheritance');
}
done_testing;
