use v5.42;
use strict;
use warnings;

# Loading without import must leave this exact source in ordinary Perl mode.
# The stock control never loads Wump; neither control imports it.
BEGIN { require Wump if $ENV{WUMP_LEGACY_LOAD} }
use JSON::PP ();
use POSIX qw(setlocale localeconv LC_NUMERIC);

my %observations;
{
	no feature 'signatures';
	sub act (&) { $_[0]->() }
	sub chan (;$) { @_ ? $_[0] + 1 : 'empty' }
	sub sel (&) { $_[0]->() }
	sub scope (&) { $_[0]->() }
	sub pocket ($) { $_[0] + 1 }
	$observations{names} = {
		prototypes => [map { prototype($_) } (\&act, \&chan, \&sel, \&scope, \&pocket)],
		values => [act { 11 }, chan(), chan(20), sel { 31 }, scope { 41 }, pocket(50)],
	};
	my $bad_call = eval 'pocket()';
	$observations{names}{prototype_error} = $@;
}

sub hint_seen () {
	my @frame = caller(0);
	return $frame[10]{'Legacy/marker'} // 'unset';
}
sub numeric_warnings () { return warnings::enabled_at_level('numeric', 0) ? 1 : 0 }
my (@hints, @numbers, @warning_modes);
push @hints, hint_seen();
{
	BEGIN { $^H{'Legacy/marker'} = 'outer' }
	push @hints, hint_seen(), eval 'hint_seen()';
	{
		BEGIN { $^H{'Legacy/marker'} = 'inner' }
		push @hints, hint_seen(), eval 'hint_seen()';
	}
	push @hints, hint_seen();
}
push @hints, hint_seen();
{
	use integer;
	push @numbers, 7 / 2;
}
push @numbers, 7 / 2;
{
	no warnings 'numeric';
	push @warning_modes, numeric_warnings();
}
push @warning_modes, numeric_warnings();
my $fatal_error;
{
	use warnings FATAL => 'numeric';
	eval { my $text = 'invalid'; my $number = $text + 0 };
	$fatal_error = $@;
}
$observations{hints} = {
	markers => \@hints, arithmetic => \@numbers,
	warning_modes => \@warning_modes, fatal_error => $fatal_error,
};

our $dynamic = 'root';
my (@events, $inner_error, $outer_error);
{
	local $SIG{__WARN__} = sub ($message) { push @events, ['warn', $dynamic, $message] };
	local $SIG{__DIE__} = sub ($message) { push @events, ['die', $dynamic, $^S ? 1 : 0, $message] };
	warn "root warning\n";
	eval {
		local $dynamic = 'outer';
		eval {
			local $dynamic = 'inner';
			local $SIG{__WARN__} = sub ($message) { push @events, ['inner warn', $dynamic, $message] };
			warn "inner warning\n";
			die "inner exception\n";
		};
		$inner_error = $@;
		warn "restored warning\n";
		die "outer exception\n";
	};
	$outer_error = $@;
	warn "root restored\n";
}
$observations{hooks} = {
	events => \@events, errors => [$inner_error, $outer_error], restored => $dynamic,
};

my ($first, $second) = ('', '');
open my $first_fh, '>', \$first or die "first scalar output: $!\n";
open my $second_fh, '>', \$second or die "second scalar output: $!\n";
my $original = select $first_fh;
my @selection;
{
	local $\ = '|';
	local $, = ':';
	print 'first', 'one';
	eval {
		local $dynamic = 'selected';
		my $saved = select $second_fh;
		push @selection, $saved == $first_fh ? 1 : 0;
		{
			local $\ = ';';
			print 'second', $dynamic;
		}
		select $saved;
		die "output exception\n";
	};
	push @selection, $@;
	print 'first', 'two';
}
push @selection, select() == $first_fh ? 1 : 0;
select $original;
close $first_fh or die "close first output: $!\n";
close $second_fh or die "close second output: $!\n";
$observations{io} = {
	first => $first, second => $second, selection => \@selection,
	restored => [$dynamic, defined($\) ? $\ : 'undef', defined($,) ? $, : 'undef'],
};

# The harness fixes LC_ALL/LANG to C. Query only: do not change process locale
# or claim coverage for locale mutation or arbitrary installed locales.
my $locale_before = setlocale(LC_NUMERIC);
my $conventions = localeconv();
$observations{locale} = {
	before => $locale_before, after => setlocale(LC_NUMERIC),
	decimal_point => $conventions->{decimal_point},
	thousands_sep => $conventions->{thousands_sep}, formatted => sprintf('%.2f', 12.5),
};

# Use the default UTF-8 serializer too: its XS entry must remain available
# while actor execution is inactive, including after require Wump.
print JSON::PP::encode_json(\%observations), "\n";
