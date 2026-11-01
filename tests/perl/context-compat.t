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
	open my $probe, '-|', $binary, "-I$lib", '-MConfig', '-e',
		'print join ":", $^V, defined(&Wump::_enable) ? 1 : 0,
			map { $Config{$_} // "undef" } qw(usemultiplicity useithreads use64bitall)' or die $!;
	my $value = do {local $/; <$probe>};
	close $probe or die "interpreter probe failed: $?\n";
	my @fields = split /:/, $value;
	is(join(':', @fields[0, 1]), "v5.42.2:$wump", 'same Perl version and correct interpreter role');
	$configuration{$binary} = [@fields[2..$#fields]];
}
is_deeply($configuration{$private}, $configuration{$stock}, 'stock and private controls match multiplicity, ithreads and integer-width configuration');

my ($source, $path) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print {$source} <<'PERL' or die $!;
use v5.42;
use strict;
use warnings;
no warnings 'experimental::args_array_with_signatures';
BEGIN {
	if (($ENV{WUMP_CONTEXT_MODE} // 'plain') ne 'plain') {
		require Wump;
		Wump->import;
	}
}
use JSON::PP 'encode_json';
my $mode = $ENV{WUMP_CONTEXT_MODE} // 'plain';
our $dynamic = 'global';
$_ = 'root';
sub pause_here () { Wump::yield() if $mode ne 'plain' }
sub context_frame ($id) {
	my @before = map {
		my @frame = caller($_);
		join ':', $frame[0], $frame[3], $frame[4] ? 1 : 0,
			!defined($frame[5]) ? 'void' : $frame[5] ? 'list' : 'scalar';
	} 0..2;
	pause_here();
	my @after = map {
		my @frame = caller($_);
		join ':', $frame[0], $frame[3], $frame[4] ? 1 : 0,
			!defined($frame[5]) ? 'void' : $frame[5] ? 'list' : 'scalar';
	} 0..2;
	return [\@before, \@after, [@_]];
}
sub middle ($id) { return scalar context_frame($id) }
sub shape ($id, $log) {
	my $context = wantarray;
	my $label = !defined($context) ? 'void' : $context ? 'list' : 'scalar';
	push @$log, $label;
	pause_here();
	push @$log, "after:$label";
	return $context ? ($id, $id + 1) : $id;
}
{ package ContextGuard;
	sub DESTROY ($self) { push @{$self->[0]}, "drop:$self->[1]" }
}
sub exercise ($id) {
	my @arguments = @_;
	my @events;
	my $frame = middle($id);
	my @list = shape($id, \@events);
	my $scalar = shape($id, \@events);
	shape($id, \@events);
	local $dynamic = "scope:$id";
	local $_ = "default:$id";
	my ($inner, $outer, @states);
	eval {
		local $dynamic = "inner:$id";
		eval { pause_here(); die "inner:$id\n" };
		$inner = $@;
		pause_here();
		push @states, $dynamic, $_, $@;
		die "outer:$id\n";
	};
	$outer = $@;
	pause_here();
	push @states, $dynamic, $_, $@;
	"word$id" =~ /(word)([0-9]+)/;
	my @captures = ($1, $2);
	pause_here();
	push @captures, $1, $2;
	my $text = 'a1a2';
	$text =~ /a[0-9]/g;
	my @positions = (pos $text);
	pause_here();
	push @positions, pos $text;
	$text =~ /a[0-9]/g;
	push @positions, pos $text;
	{
		my $guard = bless [\@events, $id], 'ContextGuard';
		push @events, 'inside';
		pause_here();
	}
	push @events, 'after';
	return [$id, \@arguments, $frame, \@list, $scalar, $inner, $outer,
		\@states, \@captures, \@positions, \@events];
}
my @results;
if ($mode eq 'many') {
	my $out = Wump::chan(8);
	for my $id (1..8) { Wump::act(sub { $out->send(exercise($id)) }) }
	push @results, scalar $out->recv for 1..8;
} else {
	push @results, exercise($_) for 1..8;
}
# Character output separates context observations from UTF-8 conversion tests;
# all observations here are ASCII. This does not change observed Perl state.
print JSON::PP->new->ascii->encode({results => [sort {$a->[0] <=> $b->[0]} @results],
	outside => [$dynamic, $_], slots => $mode eq 'plain' ? 0 : Wump::execution_slots()}), "\n";
PERL
close $source or die $!;

sub run ($binary, $mode, $slots) {
	local $ENV{WUMP_CONTEXT_MODE} = $mode;
	local $ENV{WUMPPROCS} = $slots;
	my $lib = dirname($binary) . '/lib';
	my ($errors) = tempfile(UNLINK => 1);
	# Keep stdout machine-readable, and report ordinary Perl diagnostics on
	# failure without changing the worker's exception or warning behavior.
	open my $saved, '>&', \*STDERR or die $!;
	open STDERR, '>&', $errors or die $!;
	open my $child, '-|', 'timeout', '60s', $binary, "-I$lib", '-Iperl/lib', $path or die $!;
	my $output = do {local $/; <$child>};
	close $child;
	my $status = $?;
	open STDERR, '>&', $saved or die $!;
	seek $errors, 0, 0 or die $!;
	my $diagnostics = do {local $/; <$errors>};
	is($status, 0, "$mode with $slots slots exits normally");
	is($diagnostics, '', "$mode with $slots slots emits no warnings");
	my $result = eval {decode_json($output)};
	ok(ref($result) eq 'HASH', "$mode with $slots slots returns complete observations");
	return $result;
}
my $reference = run($stock, 'plain', 1);
BAIL_OUT('stock control failed') unless ref($reference) eq 'HASH';
is_deeply($reference->{outside}, ['global', 'root'], 'stock restores dynamic and default state');
for my $config (['plain', 1], ['plain', 4], ['one', 1], ['many', 1], ['many', 2], ['many', 4]) {
	my ($mode, $slots) = @$config;
	my $actual = run($private, $mode, $slots);
	next unless ref($actual) eq 'HASH';
	is($actual->{slots}, $mode eq 'plain' ? 0 : $slots, 'actual execution-slot count matches configuration');
	is_deeply($actual->{results}, $reference->{results},
		'caller frames, arguments, wantarray, eval, localization, captures, pos and normal destruction match stock');
	is_deeply($actual->{outside}, $reference->{outside}, 'root state is restored identically to stock');
}
for my $binary ($stock, $private) {
	local $ENV{WUMPPROCS} = 4;
	my $lib = dirname($binary) . '/lib';
	open my $child, '-|', 'timeout', '60s', $binary, "-I$lib", '-e',
		q{use JSON::PP; print JSON::PP::encode_json({ascii => 'value'}), "\n"} or die $!;
	my $output = do {local $/; <$child>};
	close $child;
	is($?, 0, 'ordinary JSON::PP succeeds without importing Wump');
	is($output, "{\"ascii\":\"value\"}\n", 'Wump availability and WUMPPROCS alone do not change JSON::PP behavior');
}
for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	my $lib = dirname($private) . '/lib';
	open my $child, '-|', 'timeout', '60s', $private, "-I$lib", '-Iperl/lib', '-e',
		q{use v5.42; use Wump; use JSON::PP;
		print JSON::PP::encode_json({ascii => 'value'}), "\n";
		} or die $!;
	my $output = do {local $/; <$child>};
	close $child;
	is($?, 0, "JSON::PP succeeds with $slots slots");
	is($output, "{\"ascii\":\"value\"}\n",
		'JSON::PP default UTF-8 output agrees with stock on every slot count');
}
done_testing;
