use v5.42;
use strict;
use warnings;
use Test::More;
@ARGV == 1 or die "usage: perl $0 PERL_SOURCE\n";
my $source = shift;
my %declared;
for my $file (qw(intrpvar.h perlvars.h)) {
	open my $in, '<', "$source/$file" or die "$file: $!\n";
	while (<$in>) {
		next unless /^PERLVAR\w*\(\s*([IG]),\s*(\w+)/;
		$declared{"Perl-5.42.2/$file:$."} = [$1, $2];
	}
	close $in or die $!;
}
open my $list, '<', 'perl/taskvars' or die $!;
my %tasks;
while (<$list>) { chomp; $tasks{$_} = 1 if length && !/^#/ }
close $list or die $!;
open my $inventory, '<', 'docs/state-inventory.tsv' or die $!;
my $header = <$inventory>;
is($header, "scope\tname\tdeclaration\tclassification\tassessment\tevidence\tnote\n", 'inventory schema is explicit');
my (%seen, %selected, %wump);
my @invalid;
while (<$inventory>) {
	chomp;
	my @row = split /\t/, $_, -1;
	if (@row != 7) { push @invalid, "row $. has wrong field count"; next }
	my ($scope, $name, $declaration, $owner, $assessment, $evidence, $note) = @row;
	push @invalid, "row $. has empty evidence" unless length($assessment) && length($evidence) && length($note);
	push @invalid, "row $. has invalid classification" unless $owner =~ /\A(?:task-local|executor-local|interpreter-global|intentionally-shared|unresolved)\z/;
	if ($scope eq 'Wump') {
		push @invalid, "duplicate Wump field $name" if $wump{$name}++;
		next;
	}
	push @invalid, "duplicate declaration $declaration" if $seen{$declaration}++;
	my $expected = $declared{$declaration};
	push @invalid, "stale declaration $declaration" unless $expected
		&& $expected->[0] eq $scope && $expected->[1] eq $name;
	$selected{$name} = 1 if $scope eq 'I' && $owner eq 'task-local';
}
close $inventory or die $!;
is_deeply(\@invalid, [], 'all rows have valid ownership, evidence and pinned source references');
is_deeply([sort keys %seen], [sort keys %declared], 'every interpreter and process variable declaration is inventoried, including conditional declarations');
is_deeply([sort keys %selected], [sort keys %tasks], 'task-local classification matches the complete selector list');
open my $perl_header, '<', "$source/perl.h" or die $!;
my $perl_text = do {local $/; <$perl_header>};
close $perl_header or die $!;
$perl_text =~ /struct interpreter\s*\{\s*#\s*include "intrpvar.h"(.*?)\n\};/s
	or die 'interpreter definition missing';
my %extra = map {$_ => 1} $1 =~ /\b(Iwump_\w+)\b/g;
ok(keys(%extra), 'source includes the Wump interpreter layout');
is_deeply([sort keys %wump], [sort keys %extra],
	'additional Wump interpreter fields are explicit');
done_testing;
