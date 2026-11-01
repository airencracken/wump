use strict;
use warnings;
use Cwd 'abs_path';
use File::Temp 'tempdir';
use File::Copy 'copy';
use File::Compare 'compare';

@ARGV == 1 or die "usage: opcode-regeneration.pl SOURCE\n";
my $source = abs_path($ARGV[0]) // die "missing source\n";
my $scratch = tempdir('wump-opcodes-XXXXXX', TMPDIR => 1, CLEANUP => 1);
for my $dir (qw(regen lib lib/B)) { mkdir "$scratch/$dir" or die $! }
for my $file (qw(patchlevel.h regen/opcode.pl regen/opcodes regen/op_private regen/regen_lib.pl)) {
	copy("$source/$file", "$scratch/$file") or die "copy $file: $!\n";
}
chdir $scratch or die $!;
system $^X, 'regen/opcode.pl', '-q';
$? == 0 or die "opcode regeneration failed\n";
for my $file (qw(opcode.h opnames.h pp_proto.h lib/B/Op_private.pm)) {
	compare("$source/$file", "$scratch/$file") == 0 or die "generated opcode metadata differs: $file\n";
}
print "ok - opcode numbers, ppaddr/check tables, prototypes and B metadata match regeneration\n";
