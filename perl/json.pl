# JSON::PP's public calls otherwise share encoder/parser closure cells. Give
# each call dynamic scalar bindings so acts and reentrant callbacks retain
# their own options, depth and parse cursor. Immutable lookup tables stay shared.
sub apply_json {
	my ($source) = @_;
	my $file = "$source/cpan/JSON-PP/lib/JSON/PP.pm";
	my $text = read_file($file);
	return if index($text, '# Wump call-local JSON state.') >= 0;
	require Digest::SHA;
	Digest::SHA::sha1_hex($text) eq '5ed1bc3757182a92e9cd548e5ef6d49a597c2ac0'
		or die "unexpected pinned JSON::PP source\n";
	# The functional API's default codec is immutable after construction.
	# Prepare it while loading dependencies, before acts can race lazy init.
	$text =~ s/my \$JSON; # cache/my \$JSON = __PACKAGE__->new->utf8; # prepared immutable default codec/
		or die "missing JSON default codec\n";
	for my $spec (
		['encode', '{ # Convert', '{ # PARSE', 18],
		['decode', '{ # PARSE', '} # PARSE', 22],
	) {
		my ($kind, $open, $close, $expected) = @$spec;
		my $start = index($text, $open);
		my $end = index($text, $close, $start + length($open));
		$start >= 0 && $end > $start or die "missing JSON $kind block\n";
		my $block = substr($text, $start, $end - $start);
		my $entry = "    sub PP_${kind}_json {\n";
		my $prefix = substr($block, 0, index($block, $entry));
		my @names = $prefix =~ /^    my \$(\w+);/mg;
		@names == $expected or die "unexpected JSON $kind state fields: " . scalar(@names) . "\n";
		for my $name (@names) {
			$block =~ s/^    my \$\Q$name\E;/    our \$$name;/m or die "missing JSON state declaration $name\n";
			$block =~ s/\$\Q$name\E\b/\$wump_${kind}_$name/g;
		}
		my $locals = "        # Wump call-local JSON state.\n        local (\n"
			. join('', map {"            \$wump_${kind}_$_,\n"} @names) . "        );\n";
		$block =~ s/\Q$entry\E/$entry$locals/ or die "missing JSON $kind entry\n";
		substr($text, $start, $end - $start, $block);
	}
	write_file($file, $text);
}
1;
