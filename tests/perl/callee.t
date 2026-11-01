use v5.42;
use strict;
use warnings;
use Test::More;
use File::Basename 'dirname';
use File::Temp 'tempfile';
use Cwd 'abs_path';
use IPC::Open3 'open3';
use JSON::PP 'decode_json';

@ARGV <= 1 or die "usage: $0 [MATCHED_STOCK_PERL]\n";
my $private = abs_path($^X);
my $stock = @ARGV ? abs_path($ARGV[0]) // die "missing stock interpreter" : undef;
my @expected = map {
	my $id = $_;
	[$id, {
		(map {$_ => $id + 3} qw(named reference glob forwarded tail recursive symbolic magic)),
		method => $id * 2, super => $id * 2 + 1, blessed => $id + 5,
		overloaded => $id + 7, overload_error => 1, overload_recovered => $id + 7,
		magic_changed => $id + 9, magic_error => 1, magic_recovered => $id + 9, fetches => 4,
		scalar => $id, list => [19, $id, $id + 1, 23],
		contexts => ['scalar', 'list', 'void', 'after'], lvalue => $id + 13, bad => [1,1,1,1],
	}]
} 1..8;
sub run_case ($binary, $mode, $slots, $role) {
	local $ENV{WUMP_CALLEE_MODE} = $mode;
	local $ENV{WUMPPROCS} = $slots;
	my ($errors) = tempfile(UNLINK => 1);
	my ($input, $output);
	my $pid = open3($input, $output, '>&' . fileno($errors), 'timeout', '90s',
		$binary, '-I' . dirname($binary) . '/lib', '-Iperl/lib', 'tests/perl/callee-cases.pl');
	close $input or die $!;
	my $text = do {local $/; <$output>};
	close $output or die $!;
	waitpid($pid, 0) == $pid or die $!;
	is($?, 0, "$role $mode/$slots exits normally");
	seek $errors, 0, 0 or die $!;
	my $diagnostics = do {local $/; <$errors>};
	is($diagnostics, '', "$role $mode/$slots has no diagnostics");
	my $actual = eval {decode_json($text)};
	ok(ref($actual) eq 'ARRAY' && @$actual == 8, "$role $mode/$slots returns all worker observations")
		or return;
	for my $key (sort keys %{$expected[0][1]}) {
		is_deeply([map {[$_->[0], $_->[1]{$key}]} @$actual],
			[map {[$_->[0], $_->[1]{$key}]} @expected], "$role $mode/$slots preserves $key");
	}
}
run_case($stock, 'plain', 1, 'stock') if $stock;
run_case($private, @$_, 'private') for ['plain',1], ['plain',4], ['root',1], ['many',1], ['many',2], ['many',4];
done_testing;
