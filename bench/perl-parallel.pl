use v5.42;
use strict;
use warnings;
use Wump;
my $out = chan(4);
for (1..4) {
	act {
		my $text = '0123456789abcdef' x 262144;
		for (1..64) { $text = reverse $text }
		die "corrupt worker buffer\n" unless $text eq '0123456789abcdef' x 262144;
		$out->send(length($text) . ':' . substr($text, 0, 16));
	};
}
for (1..4) {
	my $answer = $out->recv;
	die "corrupt string: $answer\n" unless $answer eq '4194304:0123456789abcdef';
}
print "four string workers verified\n";
