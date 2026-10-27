use v5.42;
use Wump;

our %context = (request => 'outside', service => 'wump');
scope {
	my $done = chan;
	for my $name ('alpha', 'bravo') {
		act {
			local $context{request} = $name;
			yield;
			$done->send("$context{service}: request=$context{request}");
		};
	}
	say scalar $done->recv for 1..2;
};
say "$context{service}: request=$context{request}";
