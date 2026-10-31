use v5.42;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Cwd 'abs_path';
use File::Basename 'dirname';
use JSON::PP 'decode_json';

@ARGV == 2 or die "usage: perl $0 PRIVATE_PERL STOCK_PERL\n";
my ($private, $stock) = map {abs_path($_) // die "$_: $!\n"} @ARGV;
my %configuration;
for my $spec ([$private, 1], [$stock, 0]) {
	my ($binary, $wump) = @$spec;
	my $lib = dirname($binary) . '/lib';
	open my $probe, '-|', 'timeout', '60s', $binary, "-I$lib", '-MConfig', '-e',
		'print join ":", $^V, defined(&Wump::_enable) ? 1 : 0,
			map { $Config{$_} // "undef" } qw(usemultiplicity useithreads use64bitall)' or die $!;
	my $value = do {local $/; <$probe>};
	close $probe or die "interpreter probe failed: $?\n";
	my @fields = split /:/, $value;
	is(join(':', @fields[0, 1]), "v5.42.2:$wump", 'same Perl version and correct interpreter role');
	$configuration{$binary} = [@fields[2..$#fields]];
}
is_deeply($configuration{$private}, $configuration{$stock},
	'stock and private controls match multiplicity, ithreads and integer-width configuration');

sub observe ($binary, $load, $slots) {
	local $ENV{WUMP_LEGACY_LOAD} = $load;
	local $ENV{WUMPPROCS} = $slots;
	local $ENV{LC_ALL} = 'C';
	local $ENV{LANG} = 'C';
	my $lib = dirname($binary) . '/lib';
	my ($errors) = tempfile(UNLINK => 1);
	open my $saved, '>&', \*STDERR or die $!;
	open STDERR, '>&', $errors or die $!;
	open my $child, '-|', 'timeout', '60s', $binary, "-I$lib", '-Iperl/lib',
		'tests/perl/legacy-observations.pl' or die $!;
	my $output = do {local $/; <$child>};
	close $child;
	my $status = $?;
	open STDERR, '>&', $saved or die $!;
	seek $errors, 0, 0 or die $!;
	my $diagnostics = do {local $/; <$errors>};
	is($status, 0, 'legacy fixture exits normally');
	is($diagnostics, '', 'legacy fixture emits no unexpected diagnostics');
	my $result = eval {decode_json($output)};
	ok(ref($result) eq 'HASH', 'legacy fixture returns complete observations') or diag($output, $@);
	return $result;
}

my $reference = observe($stock, 0, 1);
BAIL_OUT('stock control failed') unless ref($reference) eq 'HASH';
is_deeply([sort keys %$reference], [qw(hints hooks io locale names)], 'stock observes every requested state family');
is_deeply($reference->{names}{prototypes}, ['&', ';$', '&', '&', '$'], 'stock retains legacy prototypes');
is_deeply($reference->{names}{values}, [11, 'empty', 21, 31, 41, 51], 'stock executes legacy names');
like($reference->{names}{prototype_error}, qr/Not enough arguments for main::pocket/, 'stock enforces the legacy prototype');
is_deeply($reference->{hints}{markers}, [qw(unset outer outer inner inner outer unset)], 'stock scopes hints including string eval inheritance');
is_deeply($reference->{hints}{arithmetic}, [3, 3.5], 'stock scopes integer arithmetic');
is_deeply($reference->{hints}{warning_modes}, [0, 1], 'stock scopes lexical warning policy');
like($reference->{hints}{fatal_error}, qr/Argument "invalid" isn't numeric/, 'stock retains fatal warning behavior');
is_deeply($reference->{hooks}, {
	events => [
		['warn', 'root', "root warning\n"],
		['inner warn', 'inner', "inner warning\n"],
		['die', 'inner', 1, "inner exception\n"],
		['warn', 'outer', "restored warning\n"],
		['die', 'outer', 1, "outer exception\n"],
		['warn', 'root', "root restored\n"],
	],
	errors => ["inner exception\n", "outer exception\n"], restored => 'root',
}, 'stock hooks observe nesting, eval and restored dynamic scope');
is_deeply($reference->{io}, {
	first => 'first:one|first:two|', second => 'second:selected;',
	selection => [1, "output exception\n", 1], restored => ['root', 'undef', 'undef'],
}, 'stock retains selected handles, output separators and restoration');
is_deeply($reference->{locale}, {
	before => 'C', after => 'C', decimal_point => '.', thousands_sep => '', formatted => '12.50',
}, 'stock read-only C locale queries preserve locale');

# Invalid configuration is intentional: it must not even be parsed before
# activation. Requiring Wump without import must have the same property.
for my $spec ([$stock, 0, 'stock'], [$private, 0, 'private unused'], [$private, 1, 'private required']) {
	my ($binary, $load, $mode) = @$spec;
	for my $slots (1, 4, 'invalid-unused') {
		subtest "$mode with WUMPPROCS=$slots" => sub {
			my $actual = observe($binary, $load, $slots);
			return unless ref($actual) eq 'HASH';
			is_deeply([sort keys %$actual], [sort keys %$reference], 'all observation groups are retained');
			for my $group (qw(names hints hooks io locale)) {
				is_deeply($actual->{$group}, $reference->{$group}, "$group matches unmodified Perl exactly");
			}
		};
	}
}
done_testing;
