package WumpDemo::Analysis;
use v5.42;
use strict;
use warnings;
use Exporter 'import';
use Unicode::Normalize 'NFC';
our @EXPORT_OK = qw(lines analyze_chunk reference summary);

# Load Unicode tables before the service starts its acts.
BEGIN { NFC(fc "Stra\x{df}e \x{3b1} \x{e9}") }

sub lines ($text) {
	my @lines = split /\n/, $text, -1;
	pop @lines if @lines && $lines[-1] eq '';
	s/\r\z// for @lines;
	return \@lines;
}

sub analyze_chunk ($lines, $passes, $cancelled, $max_unique = 4096) {
	my (%counts, %levels);
	my ($line_count, $word_count) = (0, 0);
	for (1..$passes) {
		return {cancelled => 1} if $cancelled->();
		for my $line (@$lines) {
			$line_count++;
			my ($level) = $line =~ /\b(ERROR|WARN|INFO|DEBUG)\b/;
			$levels{$level // 'OTHER'}++;
			while ($line =~ /([\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['\x{2019}][\p{L}\p{N}][\p{L}\p{M}\p{N}]*)*)/g) {
				my $word = NFC(fc $1);
				$word_count++;
				$counts{$word}++;
				die "Too many distinct words\n" if keys(%counts) > $max_unique;
			}
		}
	}
	return {lines => $line_count, words => $word_count, counts => \%counts, levels => \%levels};
}

# Whole-input reference: count one pass, then scale. Workers scan each chunk
# repeatedly and the collector merges their results, exercising a separate path.
sub reference ($text, $passes = 1) {
	my (%counts, %levels);
	my @tokens = $text =~ /([\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['\x{2019}][\p{L}\p{N}][\p{L}\p{M}\p{N}]*)*)/g;
	$counts{NFC(fc $_)} += $passes for @tokens;
	my $lines = lines($text);
	for my $line (@$lines) {
		my ($level) = $line =~ /\b(ERROR|WARN|INFO|DEBUG)\b/;
		$levels{$level // 'OTHER'} += $passes;
	}
	return {lines => scalar(@$lines) * $passes, words => scalar(@tokens) * $passes,
		counts => \%counts, levels => \%levels};
}

sub summary ($result) {
	my $counts = $result->{counts};
	my @words = sort { $counts->{$b} <=> $counts->{$a} || $a cmp $b } keys %$counts;
	splice @words, 20 if @words > 20;
	return {lines => $result->{lines}, words => $result->{words},
		unique_words => scalar(keys %$counts), levels => {%{$result->{levels}}},
		top_words => [map { {word => $_, count => $counts->{$_}} } @words]};
}

1;
