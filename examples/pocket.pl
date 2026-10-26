use v5.42;
use Wump;

our $request = 'outside';
sub current_request { $request }

run {
	my $done = chan;
	local $request = 'inherited context';
	{
		pocket $request = 'this act only';
		act { $done->send(current_request()) };
		say 'parent: ', current_request();
		say 'child: ', scalar $done->recv;
	}
	say 'after block: ', current_request();
};
say 'outside: ', current_request();
