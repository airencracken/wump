use strict;
use warnings;
use Config;
use Cwd 'abs_path';
use Text::ParseWords 'shellwords';

@ARGV == 2 or die "usage: $0 SOURCE BUILD\n";
my ($source, $build) = map { abs_path($_) // die "$_: $!\n" } @ARGV;
my @command = (shellwords($Config{cc}), shellwords($Config{ccflags}),
	shellwords($Config{cccdlflags}), shellwords($Config{lddlflags}),
	"-I$source", 'tests/perl/root-fixture.c', '-o', "$build/root-fixture.$Config{dlext}");
system @command;
$? == 0 or die "native root fixture failed to build: $?\n";
open my $module, '>', "$build/RootFixture.pm" or die "fixture loader: $!\n";
print {$module} <<'PM' or die "fixture loader write: $!\n";
package RootFixture;
use strict;
use warnings;
use Config;
use File::Basename 'dirname';
use DynaLoader ();
my $path = dirname(__FILE__) . "/root-fixture.$Config{dlext}";
my $handle = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, 'boot_RootFixture') or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub('RootFixture::bootstrap', $symbol, $path)->();
1;
PM
close $module or die "fixture loader close: $!\n";
print "Native root fixture built.\n";
