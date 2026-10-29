use v5.42;
use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd 'abs_path';
use File::Basename 'dirname';
use File::Temp 'tempfile';
use IPC::Open3;

my $private = abs_path(shift // die "Usage: perl $0 PRIVATE_PERL\n");
my $directory = dirname($private);
my $launcher = "$FindBin::Bin/../../examples/mojo/dashboard.pl";
for my $slots (1, 4) {
	local $ENV{WUMPPROCS} = $slots;
	for my $case (
		[['--no-such-wump-option'], qr/Usage:/, 'unknown option'],
		[['unexpected-argument'], qr/Unexpected arguments/, 'positional argument'],
		[['--workers', '0'], qr/Invalid workers/, 'parsed worker configuration'],
	) {
		my ($args, $expected, $name) = @$case;
		my ($errors) = tempfile(UNLINK => 1);
		my ($input, $output);
		my $pid = open3($input, $output, '>&' . fileno($errors),
			$private, "-I$directory/lib", $launcher, @$args);
		close $input or die "Close child input: $!\n";
		my $stdout = do { local $/; <$output> };
		close $output or die "Close child output: $!\n";
		waitpid($pid, 0) == $pid or die "Wait for launcher: $!\n";
		isnt($?, 0, "$name is rejected with $slots slots");
		is($stdout, '', 'failed configuration emits no server events');
		seek $errors, 0, 0 or die "Rewind error log: $!\n";
		my $stderr = do { local $/; <$errors> };
		like($stderr, $expected, 'configuration reaches its intended validation');
		unlike($stderr, qr/runtime compilation is not supported/,
			'option parsing does not enter the parallel compiler gate');
	}
}
done_testing;
