use v5.42;
use Wump;

our $request = 'outside';
run {
	my $done = chan;
	for my $name ('alpha', 'bravo') {
		local $request = $name;
		act {
			yield;
			$done->send("request=$request");
		};
	}
	say scalar $done->recv for 1..2;
};
say "request=$request";
