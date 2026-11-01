# Add a real core opcode. The lexer selects it only within use Wump scope;
# qualified/indirect calls retain their existing Perl/XS compatibility path.
sub apply_yield {
	my ($source) = @_;
	my $opcodes = read_file("$source/regen/opcodes");
	my $yield_entry = "wumpyield\tWump task yield\t\tck_null\t\t0\n";
	my $act_entry = "wumpact\t\tWump task creation\tck_null\t\t1\tS\n";
	my @entries = ($yield_entry, $act_entry,
		"wumpchan\tWump channel creation\tck_null\t\t1\tS\n",
		"wumpsleep\tWump task sleep\t\tck_null\t\t1\tS\n",
		"wumpsel\t\tWump channel selection\tck_null\t\t2\tS S\n");
	my $original = $opcodes;
	my $removed = 0;
	for my $entry (reverse @entries) { $removed += $original =~ s/\Q$entry\E\z// }
	$original =~ s/\n\z// if $removed;
	require Digest::SHA;
	Digest::SHA::sha256_hex($original) eq '9bd5cfd093b1b11ae79a1605a90e33d15685f2d0940a8dd9b0a5f8190a34f6e0'
		or die "unexpected opcode definitions; audit the pinned transformation\n";
	write_file("$source/regen/opcodes", $original . "\n" . join('', @entries));
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
	my $thread_ops = read_file("$source/ext/Opcode/Opcode.pm");
	my ($old_thread_ops) = $thread_ops =~ /(    lock(?: wumpyield(?: wumpact(?: wumpchan(?: wumpsleep(?: wumpsel)?)?)?)?)?\n\n=item :default)/;
	defined($old_thread_ops) or die "unknown Opcode thread classification\n";
	edit('ext/Opcode/Opcode.pm', $old_thread_ops,
		"    lock wumpyield wumpact wumpchan wumpsleep wumpsel\n\n=item :default");
	my $act_deparse = <<'PERL';
sub pp_wumpact {
    my ($self, $op) = @_;
    return 'act(' . $self->deparse($op->first, 0) . ')';
}
PERL
	edit('lib/B/Deparse.pm', 'sub pp_stub { "()" }',
		'sub pp_stub { "()" }' . "\n\n" . $act_deparse);
	my $scalar_deparse = <<'PERL';

sub pp_wumpchan {
    my ($self, $op) = @_;
    return 'chan(' . $self->deparse($op->first, 0) . ')';
}

sub pp_wumpsleep {
    my ($self, $op) = @_;
    return 'sleep(' . $self->deparse($op->first, 0) . ')';
}
PERL
	edit('lib/B/Deparse.pm', $act_deparse, $act_deparse . $scalar_deparse);
	my $sel_deparse = <<'PERL';

sub pp_wumpsel {
    my ($self, $op) = @_;
    return 'sel(' . $self->deparse($op->first, 0) . ', ' . $self->deparse($op->last, 0) . ')';
}
PERL
	edit('lib/B/Deparse.pm', $scalar_deparse, $scalar_deparse . $sel_deparse);
}
1;
