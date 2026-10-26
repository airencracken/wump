use strict;
use warnings;
use Digest::SHA 'sha256_hex';
use File::Find 'find';

@ARGV == 1 or die "usage: $0 SOURCE\n";
my $source = $ARGV[0];
sub snapshot {
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
my $before = snapshot();
system 'perl', 'perl/apply.pl', $source;
$? == 0 or die "patcher failed: $?\n";
my $after = snapshot();
my @changed = grep { !exists $before->{$_} || $before->{$_} ne $after->{$_} } keys %$after;
push @changed, grep { !exists $after->{$_} } keys %$before;
die "reapplying patches changed source:\n", join("\n", sort @changed), "\n" if @changed;
print "ok - reapplying patches preserves every source file\n";
