# Add a real core opcode. The lexer selects it only within use Wump scope;
# qualified/indirect calls retain their existing Perl/XS compatibility path.
sub apply_yield {
	my ($source) = @_;
	my $opcodes = read_file("$source/regen/opcodes");
	my $entry = "wumpyield\tWump task yield\t\tck_null\t\t0\n";
	my $original = $opcodes;
	$original =~ s/\n\Q$entry\E\z//;
	require Digest::SHA;
	Digest::SHA::sha256_hex($original) eq '9bd5cfd093b1b11ae79a1605a90e33d15685f2d0940a8dd9b0a5f8190a34f6e0'
		or die "unexpected opcode definitions; audit the pinned transformation\n";
	write_file("$source/regen/opcodes", $original . "\n" . $entry);
	# Generate all opcode metadata from the pinned upstream generator rather
	# than maintaining independent opcode numbers, ppaddr tables or B flags.
	my $pid = fork();
	defined($pid) or die "fork opcode generator: $!\n";
	if (!$pid) {
		chdir $source or die "chdir $source: $!\n";
		exec $^X, 'regen/opcode.pl', '-q';
		die "exec opcode generator: $!\n";
	}
	waitpid($pid, 0) == $pid && $? == 0 or die "opcode regeneration failed\n";
	my $hook = <<'C';
    /* Wump's nullary yield is a core operation, not an entersub/XS call.
     * Earlier lexer rules retain qualified names, methods and quoted keys. */
    if (memEQs(PL_tokenbuf, len, "yield") && PL_expect != XOPERATOR
            && PL_expect != XREF && PL_hintgv && GvHV(PL_hintgv)) {
        SV **enabled = hv_fetchs(GvHV(PL_hintgv), "Wump/keywords", 0);
        if (enabled && SvTRUE(*enabled)) {
            FUN0(OP_WUMPYIELD);
        }
    }
C
	edit('toke.c', '    /* Wump syntax is lexical:', $hook . '    /* Wump syntax is lexical:');
	edit('lib/B/Deparse.pm', 'sub pp_stub {', "sub pp_wumpyield { return 'yield()' }\n\nsub pp_stub {");
	edit('ext/Opcode/Opcode.pm', "    lock\n\n=item :default",
		"    lock wumpyield\n\n=item :default");
}
1;
