use v5.42;
use Wump;

my $done = chan;
for my $separator (':', '|') {
	act {
		local $/ = $separator;
		my $text = "alpha${separator}bravo${separator}";
		open my $fh, '<', \$text or die "scalar input: $!";
		yield;
		my @records = <$fh>;
		chomp @records;
		close $fh;
		$done->send("separator=$separator records=" . join(',', @records));
	};
}
say scalar $done->recv for 1..2;
