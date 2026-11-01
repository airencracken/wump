use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1,2,4) {
	local $ENV{WUMPPROCS}=$slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture; use JSON::PP ();
		use Scalar::Util qw(dualvar);
		sub observe ($operation,$input) {
			my $value=$input;
			my $alias=\$value;
			my $copy=$value;
			my $warnings=0;
			local $SIG{__WARN__}=sub {$warnings++};
			pos($value)=1 if defined($value) && length($value)>1;
			my @result=$operation eq 'encode' ? utf8::encode($value) : utf8::decode($value);
			my $utf8=!!utf8::is_utf8($value);
			my $position=pos($value);
			my $bytes=$value;
			utf8::encode($bytes) if utf8::is_utf8($bytes);
			my $old=$copy;
			utf8::encode($old) if utf8::is_utf8($old);
			return [\@result,$utf8,$position,defined($bytes)?unpack('H*',$bytes):undef,
				defined($old)?unpack('H*',$old):undef,$warnings,$$alias eq $value];
		}
		our (@cases,@expected);
		BEGIN {
			@cases=('', 'ascii', "Caf\x{e9}", "\x{100}\0\x{10000}", "\xc4\x80", "\xc3\x28", 123, dualvar(7,'seven'),undef);
			@expected=map {
				my $op=$_;
				[map {JSON::PP->new->canonical->ascii->encode(observe($op,$_))} @cases]
			} qw(encode decode);
		}
		my $out=chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..16) {
					for my $op (0,1) {
						for my $i (0..$#cases) {
							my $actual=JSON::PP->new->canonical->ascii->encode(observe($op?'decode':'encode',$cases[$i]));
							die "conversion changed at $op/$i: $actual versus $expected[$op][$i]" unless $actual eq $expected[$op][$i];
						}
					}
					yield;
				}
				$out->send(1);
			};
		}
		die "missing converters" if grep {$out->recv!=1} 1..8;
		print "native UTF-8 observations match inactive Perl\n";
	},0,qr/\Anative UTF-8 observations match inactive Perl\n\z/,
		"UTF-8 aliases, COW, positions, invalid bytes and return contexts on $slots slots");

	WumpTest::check_program(q{
		use Wump; use RootFixture;
		my $out=chan(4);
		for (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for my $operation (\&utf8::encode,\&utf8::decode) {
					my ($value,$seen);
					{
						local $SIG{__WARN__}=sub {my @grow=(1..8192); Wump::yield(); $seen++};
						$operation->($value);
					}
					die "warning hook lost" unless $seen;
					$value=undef;
					{
						local $SIG{__WARN__}=sub {Wump::yield(); die "conversion warning failed\n"};
						eval {$operation->($value)};
						die "warning exception lost: $@" unless $@ =~ /conversion warning failed/;
					}
					$value='after exception'; $operation->($value);
					die "guard survived exception" unless $value eq 'after exception';
				}
				$out->send(1);
			};
		}
		die "missing warning workers" if grep {$out->recv!=1} 1..8;
		print "yielding conversion callbacks and unwind verified\n";
	},0,qr/\Ayielding conversion callbacks and unwind verified\n\z/,
		"native XS frames survive warning stack growth, yielding and throws on $slots slots");
}

for my $slots (2,4) {
	local $ENV{WUMPPROCS}=$slots;
	WumpTest::check_program(q{
		use Wump;
		{package Utf8Tie; our $fetches=0;
		 sub TIESCALAR {bless [],shift}
		 sub FETCH {$fetches++; die "unexpected FETCH\n"}
		 sub STORE {die "unexpected STORE\n"}}
		tie my $bad,'Utf8Tie';
		for my $operation (\&utf8::encode,\&utf8::decode) {
			for my $argument ($bad,[],bless({},'Utf8Object')) {
				eval {$operation->($argument)};
				die "unsupported input admitted: $@" unless $@ =~ /requires a plain scalar/;
			}
			eval {$operation->('read-only literal')};
			die "readonly conversion admitted" unless $@ =~ /read-only/;
			my $value='recovered'; $operation->($value);
			die "conversion did not recover" unless $value eq 'recovered';
		}
		die "tied callback ran" if $Utf8Tie::fetches;
		eval {utf8::valid('text')};
		die "unrelated UTF-8 entry admitted" unless $@ =~ /XS function has not declared parallel safety/;
		print "unsupported inputs reject without callbacks\n";
	},0,qr/\Aunsupported inputs reject without callbacks\n\z/,
		"conversion input and admission boundaries remain explicit on $slots slots");
}
done_testing;
