use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use Encode ();
		our ($encoder, @cases, @expected);
		BEGIN {
			$encoder = Encode::find_encoding('UTF-8');
			@cases = ('ascii', "a\0b", "Caf\x{e9}", "\x{100}\x{10000}", 123.25, !!0, !!1, undef);
			@expected = map {
				my $bytes = $encoder->encode($_, 0);
				[defined($bytes) ? unpack('H*', $bytes) : undef,
				 defined($bytes) ? $encoder->decode($bytes, 0) : undef]
			} @cases;
		}
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..16) {
					for my $i (0..$#cases) {
						my $bytes;
						eval { $bytes = $encoder->encode($cases[$i], 0); 1 }
							or die "encode case $i failed: $@";
						die "encoded definedness changed\n" unless defined($bytes) == defined($expected[$i][0]);
						next unless defined $bytes;
						die "encoded bytes changed\n" unless unpack('H*', $bytes) eq $expected[$i][0];
						die "encoded output is wide\n" if utf8::is_utf8($bytes);
						my $text;
						eval { $text = $encoder->decode($bytes, 0); 1 }
							or die "decode case $i failed: $@";
						die "decoded text changed\n" unless $text eq $expected[$i][1];
					}
					my $source = "Caf\x{e9}";
					my $source_alias = \$source;
					my $encoded = $encoder->encode($source, 1);
					die "CHECK 1 encode lost source alias\n" unless $$source_alias eq '' && $encoded eq "Caf\xc3\xa9";
					my $encoded_alias = \$encoded;
					die "CHECK 1 decode changed\n" unless $encoder->decode($encoded, 1) eq "Caf\x{e9}" && $$encoded_alias eq '';
					my $invalid = "\xff";
					eval { $encoder->decode($invalid, 1) };
					die "CHECK 1 failed to reject invalid UTF-8: $@" unless $@ =~ /UTF-8/ && $invalid eq "\xff";
					yield;
				}
				$out->send(1);
			};
		}
		die "missing encoding workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			for my $check (2, sub { die "encoding CHECK callback ran\n" }) {
				eval { $encoder->encode($cases[2], $check) };
				die "CHECK policy bypassed: $@" unless $@ =~ /CHECK 0 or 1/;
			}
			{ package EncodingTie; sub TIESCALAR { bless {}, shift }
				sub FETCH { die "encoding FETCH ran\n" } }
			tie my $bad, 'EncodingTie';
			eval { $encoder->encode($bad, 0) };
			die "magical encoding source admitted: $@" unless $@ =~ /plain scalar/;
			eval { Encode::encode('UTF-8', 'text') };
			die "encoding audit admitted unrelated XS: $@" unless $@ =~ /XS function has not declared parallel safety/;
		}
		die "encoding source changed\n" unless $cases[2] eq "Caf\x{e9}";
		print "UTF-8 methods preserve shared sources, encoded bytes and admission\n";
	}, 0, qr/\AUTF-8 methods preserve shared sources, encoded bytes and admission\n\z/,
		"UTF-8 encoding and decoding run on $slots slots with shared inputs");
}

for my $slots (2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use Encode ();
		{ package YieldEncoding;
			our @ISA; BEGIN { @ISA = ('Encode::utf8') }
			sub renewed {
				my $self = shift;
				my @padding = (1) x 20000;
				Wump::yield();
				$self->{calls}++;
				die "renewed failed\n" if $self->{fail};
				return 0;
			}
		}
		my $bytes = "Caf\xc3\xa9";
		my $out = chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				my $object = bless {strict_utf8 => 1, calls => 0}, 'YieldEncoding';
				die "renewed decode changed\n" unless $object->decode($bytes, 0) eq "Caf\x{e9}";
				die "renewed received a copied object\n" unless $object->{calls} == 1;
				$object->{fail} = 1;
				eval { $object->decode($bytes, 0) };
				die "renewed exception changed: $@" unless $@ eq "renewed failed\n";
				$object->{fail} = 0;
				die "decode failed after exception\n" unless $object->decode($bytes, 0) eq "Caf\x{e9}";
				$out->send(1);
			};
		}
		die "missing renewed workers\n" if grep { $out->recv != 1 } 1..8;
		print "UTF-8 decode preserves renewed identity, migration and exception recovery\n";
	}, 0, qr/\AUTF-8 decode preserves renewed identity, migration and exception recovery\n\z/,
		"UTF-8 decode callbacks survive stack growth on $slots slots");
}
done_testing;
