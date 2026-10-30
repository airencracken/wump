use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use Digest::MD5 (); use Digest::SHA (); use MIME::Base64 ();
		our (@cases, @expected, @functions, $wide);
		BEGIN {
			@functions = (\&Digest::MD5::md5, \&Digest::MD5::md5_hex, \&Digest::MD5::md5_base64,
				map { no strict 'refs'; \&{"Digest::SHA::$_"} }
				map { ($_, "${_}_hex", "${_}_base64") } qw(sha1 sha224 sha256 sha384 sha512 sha512224 sha512256));
			@cases = ('', 'abc', "a\0b", "Caf\x{e9}");
			utf8::upgrade($cases[3]);
			@expected = map {
				my $text = $_;
				[map { unpack('H*', $_->($text)) } @functions]
			} @cases;
			$wide = "\x{100}";
		}
		die "MD5 vector changed\n" unless Digest::MD5::md5_hex('abc') eq '900150983cd24fb0d6963f7d28e17f72';
		die "SHA-1 vector changed\n" unless Digest::SHA::sha1_hex('abc') eq 'a9993e364706816aba3e25717850c26c9cd0d89d';
		die "base64 vector changed\n" unless MIME::Base64::encode_base64('abc', '') eq 'YWJj';
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..8) {
					for my $i (0..$#cases) {
						for my $f (0..$#functions) {
							die "digest changed\n" unless unpack('H*', $functions[$f]->($cases[$i])) eq $expected[$i][$f];
						}
						my $encoded = MIME::Base64::encode_base64($cases[$i], '');
						die "base64 round trip changed\n" unless MIME::Base64::decode_base64($encoded) eq $cases[$i];
					}
					yield;
				}
				for my $call (sub { Digest::MD5::md5_hex($wide) }, sub { Digest::SHA::sha1($wide) },
					sub { MIME::Base64::encode_base64($wide) }) {
					eval { $call->() };
					die "wide byte conversion admitted: $@" unless $@ =~ /Wide character/;
				}
				$out->send(1);
			};
		}
		die "missing byte workers\n" if grep { $out->recv != 1 } 1..8;
		die "shared byte source downgraded\n" unless utf8::is_utf8($cases[3]) && $cases[3] eq "Caf\x{e9}";
		if (Wump::execution_slots() > 1) {
			{ package ByteTie; sub TIESCALAR { bless {}, shift } sub FETCH { die "byte FETCH ran\n" } }
			tie my $bad, 'ByteTie';
			for my $call (sub { Digest::MD5::md5($bad) }, sub { Digest::SHA::sha1($bad) },
				sub { MIME::Base64::encode_base64($bad) }, sub { MIME::Base64::decode_base64($bad) }) {
				eval { $call->() };
				die "magical byte argument admitted: $@" unless $@ =~ /plain scalar/;
			}
			eval { Digest::MD5->new };
			die "byte audit admitted mutable digest contexts: $@" unless $@ =~ /XS function has not declared parallel safety/;
		}
		print "functional digests and base64 preserve vectors, shared bytes and admission\n";
	}, 0, qr/\Afunctional digests and base64 preserve vectors, shared bytes and admission\n\z/,
		"functional digest and base64 entries run on $slots slots");
}
done_testing;
