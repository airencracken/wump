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
		[['--listen', 'invalid'], qr/Invalid listen location/, 'invalid listen location'],
		[['--workers', '0'], qr/Invalid workers/, 'parsed worker configuration'],
		[['--workers', '0'], qr/Invalid workers/, 'compile-time worker configuration', 1],
		[[], qr/syntax OK/, 'compile-only bootstrap', 1, 1],
	) {
		my ($args, $expected, $name, $compile, $success) = @$case;
		my ($errors) = tempfile(UNLINK => 1);
		my ($input, $output);
		my $pid = open3($input, $output, '>&' . fileno($errors),
			$private, "-I$directory/lib", ($compile ? '-c' : ()), $launcher, @$args);
		close $input or die "Close child input: $!\n";
		my $stdout = do { local $/; <$output> };
		close $output or die "Close child output: $!\n";
		waitpid($pid, 0) == $pid or die "Wait for launcher: $!\n";
		if ($success) { is($?, 0, "$name succeeds with $slots slots") }
		else { isnt($?, 0, "$name is rejected with $slots slots") }
		is($stdout, '', 'failed configuration emits no server events');
		seek $errors, 0, 0 or die "Rewind error log: $!\n";
		my $stderr = do { local $/; <$errors> };
		like($stderr, $expected, 'configuration reaches its intended validation');
		unlike($stderr, qr/runtime compilation is not supported/,
			'option parsing does not enter the parallel compiler gate');
	}
}
for my $slots (1, 4) {
	my ($errors) = tempfile(UNLINK => 1);
	my ($input, $output);
	my $code = q{
		BEGIN { $ENV{MOJO_NO_TLS} = $ENV{MOJO_NO_NNR} = $ENV{MOJO_NO_SOCKS} = 1 }
		use Wump; use Wump::Mojo::Daemon;
		CHECK {
			$ENV{MOJO_REUSE} = 'unrelated:1:900,unrelated:2:901';
			my $server = Wump::Mojo::Daemon->new(listen => ['http://127.0.0.1:0'], silent => 1);
			$server->prepare;
			die "listener preparation lost exports\n" unless $ENV{MOJO_REUSE} eq 'unrelated:1:900,unrelated:2:901';
			for my $id (@{$server->acceptors}) {
				die "listener retained its fork export\n" if $server->ioloop->acceptor($id)->{reuse};
			}
			die "listener was not bound\n" unless $server->ports->[0] > 0;
			$server->stop;
		}
		sub reject_late_prepare {
			eval { Wump::Mojo::Daemon->new->prepare };
			die "late preparation admitted: $@" unless $@ =~ /prepare listeners before program execution/;
		}
		reject_late_prepare();
		END { reject_late_prepare() }
		print "listener ownership prepared\n";
	};
	local $ENV{WUMPPROCS} = $slots;
	my $pid = open3($input, $output, '>&' . fileno($errors), $private,
		"-I$directory/lib", '-Iperl/lib', '-e', $code);
	close $input or die "Close child input: $!\n";
	my $stdout = do { local $/; <$output> };
	waitpid($pid, 0) == $pid or die "Wait for listener preparation: $!\n";
	is($?, 0, "listener preparation succeeds with $slots slots");
	is($stdout, "listener ownership prepared\n", 'preparation preserves unrelated exports and removes owned markers');
	seek $errors, 0, 0 or die "Rewind preparation log: $!\n";
	my $stderr = do { local $/; <$errors> };
	is($stderr, '', 'listener teardown emits no compiler or cleanup errors');
}
done_testing;
