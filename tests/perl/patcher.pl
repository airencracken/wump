use strict;
use warnings;
use Digest::SHA 'sha256_hex';
use File::Find 'find';
use File::Copy 'copy';
use File::Basename 'dirname';
use File::Path 'make_path';
use File::Temp 'tempdir';

@ARGV == 1 or die "usage: $0 SOURCE\n";
my $source = $ARGV[0];
sub snapshot {
	my ($source) = @_;
	my %files;
	find({no_chdir => 1, wanted => sub {
		return unless -f $_ && /\.(?:c|h|xs|pm|y|act)\z/;
		open my $fh, '<', $_ or die "$_: $!\n";
		binmode $fh;
		local $/;
		$files{$_} = sha256_hex(<$fh>);
	}}, $source);
	return \%files;
}
my $before = snapshot($source);
system 'perl', 'perl/apply.pl', $source;
$? == 0 or die "patcher failed: $?\n";
my $after = snapshot($source);
my @changed = grep { !exists $before->{$_} || $before->{$_} ne $after->{$_} } keys %$after;
push @changed, grep { !exists $after->{$_} } keys %$before;
die "reapplying patches changed source:\n", join("\n", sort @changed), "\n" if @changed;
print "ok - reapplying patches preserves every source file\n";

my $legacy = tempdir('wump-key-upgrade-XXXXXX', TMPDIR => 1, CLEANUP => 1);
for my $file (keys %$after) {
	(my $relative = $file) =~ s/^\Q$source\E\/// or die "unexpected path: $file\n";
	make_path(dirname("$legacy/$relative"));
	copy($file, "$legacy/$relative") or die "copy $file: $!\n";
}
for my $file ('perl.c', 'sv.c') {
	open my $input, '<', "$legacy/$file" or die "$file: $!\n";
	local $/;
	my $text = <$input>;
	close $input or die "$file: $!\n";
	# Restore the earlier key-lock lifecycle without touching the other
	# generated patches. Upgrading must preserve exactly one mutex init.
	$text =~ s/^    (?:aTHX->Iwump_memory = NULL;|Perl_wump_memory_(?:init|destroy)\(aTHX\);)\n//mg;
	open my $output, '>', "$legacy/$file" or die "$file: $!\n";
	print {$output} $text or die "$file: $!\n";
	close $output or die "$file: $!\n";
}
{
	my $file = "$legacy/pp_hot.c";
	open my $input, '<', $file or die "$file: $!\n";
	local $/;
	my $text = <$input>;
	close $input or die "$file: $!\n";
	# Recreate the previous read-only load guards in a complete generated tree.
	# Reapplying must upgrade all five sites and preserve every other patch.
	my $count = $text =~ s{
		^([ ]*)if\ \(PL_wump_task(?:\ &&\ !localizing(?:\ &&\ !\(PL_op->op_private\ &\ OPpDEREF\))?)?\)\ \{\n
		\1\ \ \ \ bool\ handled;\n
		(\1\ \ \ \ (?:SV\ \*)?\w+\ =\ Perl_wump_load_[ah]v[^\n]+\n)
		\1\ \ \ \ if\ \(handled\ &&\ \(!lval\ \|\|\ \w+\ !=\ &PL_sv_undef\)\)([^\n]+)\n
		\1\}
	}{"$1" . "if (PL_wump_task && !lval) {\n$1    bool handled;\n$2$1    if (handled)$3\n$1}"}gmex;
	$count == 5 or die "expected five existing-lvalue guards, found $count\n";
	$text =~ s{\n/\* Wump existing lvalue loads \*/\n}{} or die "missing lvalue upgrade marker\n";
	open my $output, '>', $file or die "$file: $!\n";
	print {$output} $text or die "$file: $!\n";
	close $output or die "$file: $!\n";
}
system 'perl', 'perl/apply.pl', $legacy;
$? == 0 or die "legacy lifecycle upgrade failed: $?\n";
my $upgraded = snapshot($legacy);
for my $file (keys %$after) {
	(my $relative = $file) =~ s/^\Q$source\E\///;
	$upgraded->{"$legacy/$relative"} eq $after->{$file}
		or die "legacy lifecycle upgrade changed $relative\n";
}
print "ok - upgrading earlier key-lock lifecycle and read-only element loads preserves the complete generated tree\n";
