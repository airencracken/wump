use strict;
use warnings;
use Cwd 'abs_path';
use File::Temp 'tempdir';
use File::Copy 'copy';
use File::Compare 'compare';

@ARGV == 1 or die "Usage: perl $0 SOURCE\n";
my $source = abs_path($ARGV[0]) // die "Missing source directory\n";
open my $version, '-|', 'bison', '--version' or die "Bison 3.8.2 is required for parser verification: $!\n";
my $banner = do { local $/; <$version> };
close $version or die "Cannot query Bison\n";
$banner =~ /^bison .*\b3\.8\.2\s*$/m or die "Parser verification requires the pinned Bison 3.8.2\n";
my $scratch = tempdir('wump-parser-XXXXXX', TMPDIR => 1, CLEANUP => 1);
mkdir "$scratch/regen" or die $!;
for my $file (qw(perly.y perly.act perly.h perly.tab regen_perly.pl regen/regen_lib.pl)) {
	copy("$source/$file", "$scratch/$file") or die "Copy $file: $!\n";
}
chdir $scratch or die $!;
system $^X, 'regen_perly.pl';
$? == 0 or die "Parser regeneration failed: $?\n";
for my $file (qw(perly.act perly.h perly.tab)) {
	compare("$source/$file", "$scratch/$file") == 0
		or die "Patched $file differs from actual Bison regeneration\n";
}
print "ok - patched parser actions, tables and provenance match Bison 3.8.2 regeneration\n";
