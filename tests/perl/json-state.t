use v5.42;
use strict;
use warnings;
use Test::More;
use JSON::PP ();

# These regressions run without activating Wump. Reentrant JSON callbacks must
# not replace an outer call's options or cursor even on a single native thread.
{
	package JsonNestedValue;
	sub TO_JSON {
		my $inner=JSON::PP->new->canonical->ascii->encode({nested=>[1,2]});
		die "bad nested encoding" unless $inner eq '{"nested":[1,2]}';
		return {word=>"\x{100}"};
	}
}
my $encoder=JSON::PP->new->canonical->utf8->pretty->convert_blessed;
my $expected=$encoder->encode({object=>{word=>"\x{100}"},tail=>[1,2]});
my $actual=$encoder->encode({object=>bless({},'JsonNestedValue'),tail=>[1,2]});
is($actual,$expected,'nested encoding preserves outer UTF-8, formatting and depth');
is($encoder->encode({object=>{word=>"\x{100}"},tail=>[1,2]}),$expected,'later calls retain the configured options');
my $calls=0;
my $decoder=JSON::PP->new->filter_json_object(sub {
	my $value=$_[0];
	my $nested=JSON::PP->new->decode('{"inside":99}');
	die 'bad nested parsing' unless $nested->{inside}==99;
	$calls++;
	return $value;
});
my $decoded=eval {$decoder->decode('{"one":{"two":2},"three":[3,4]}')};
is($@,'','nested decoding retains the outer parser cursor');
is_deeply($decoded,{one=>{two=>2},three=>[3,4]},'nested decoding preserves every field');
is($calls,2,'nested decoder does not invoke the outer callback');
$decoder->filter_json_object(sub {die "filter exception\n"});
eval {$decoder->decode('{"x":1}')};
like($@,qr/filter exception/,'filter exceptions propagate normally');
$decoder->filter_json_object(undef);
is_deeply($decoder->decode('{"after":42}'),{after=>42},'parser state restores after a callback exception');
my $json=JSON::PP::encode_json({word=>"\x{100}",yes=>JSON::PP::true});
my $copy=JSON::PP::decode_json($json);
is($copy->{word},"\x{100}",'prepared functional codec preserves Unicode');
ok($copy->{yes},'prepared functional codec preserves booleans');
my ($prefix,$consumed)=$decoder->decode_prefix('{"prefix":1} trailing');
is_deeply($prefix,{prefix=>1},'decode_prefix preserves the decoded object');
is($consumed,12,'decode_prefix preserves the consumed length');
done_testing;
