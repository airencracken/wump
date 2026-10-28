use v5.42;
use strict;
use warnings;
use Test::More;
use Wump;
use RootFixture;
use lib 'tests/perl/lib';
use WumpTest ();

alarm 30;
eval { RootFixture::key_too_large() };
like($@, qr/hash keys must be smaller/, 'oversized keys throw before taking the table mutex');
my %usable;
$usable{'ordinary key after exception'} = 42;
is($usable{'ordinary key after exception'}, 42, 'key interning works after a caught argument error');

my ($warning, $count);
{
	local $SIG{__WARN__} = sub ($text) {
		$warning = $text;
		my $key = join '-', 'fresh hook key', ++$count;
		$usable{$key} = $count;
		yield;
	};
	RootFixture::key_missing($_) for 0, 1;
}
like($warning, qr/Attempt to free nonexistent shared string/, 'missing legacy key reports the normal warning');
is($usable{'fresh hook key-1'}, 1, 'warning hooks can intern new keys and yield without a held native mutex');
is($usable{'fresh hook key-2'}, 2, 'UTF-8 normalization buffers are released before yielding warning hooks');

{
	local $SIG{__WARN__} = sub { die "warning hook failed\n" };
	for my $utf8 (0, 1) {
		eval { RootFixture::key_missing($utf8) };
		like($@, qr/warning hook failed/, "warning-hook exceptions propagate for encoding $utf8");
	}
}
$usable{'after warning exception'} = 99;
is($usable{'after warning exception'}, 99, 'key interning remains usable after a warning hook throws');

WumpTest::check_program(q{
	use Wump;
	use RootFixture;
	my $ready = chan;
	my $park = chan;
	act {
		local $SIG{__WARN__} = sub { $ready->send(1); $park->recv };
		RootFixture::key_missing(1);
	};
	$ready->recv;
	print "main returned\n";
}, 0, qr/\Amain returned\n\z/,
	'abandoned warning hooks retain no native UTF-8 conversion buffer');

WumpTest::check_program(q{
	use threads;
	my @workers = map {
		my $id = $_;
		threads->create(sub {
			my %values;
			$values{"worker-$id/key-$_"} = $_ for 1..128;
			return scalar keys %values;
		})
	} 1..4;
	print join(',', map { $_->join } @workers), "\n";
}, 0, qr/\A128,128,128,128\n\z/,
	'ordinary cloned interpreters initialize independent key-table mutexes');
done_testing;
