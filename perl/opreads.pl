# Prepare plain scalar operands before the original opcode can inspect cached
# flags or raw bodies. Mixed magical/reference operations keep their native
# callback and alias paths; they need a separate operand audit.
sub apply_opreads {
	my ($source) = @_;
	my @arithmetic = qw(pow multiply divide modulo subtract left_shift right_shift
		bit_and bit_or nbit_and nbit_or sbit_and sbit_or
		i_multiply i_divide i_modulo i_add i_subtract);
	my @comparisons = qw(lt gt le ge ne ncmp sle seq sne scmp i_lt i_gt i_le i_ge i_eq i_ne i_ncmp);
	for my $name (qw(ncmp scmp i_ncmp)) {
		opcode_write_guard($source, 'pp.c', $name, 'PAD_SV(PL_op->op_targ)');
	}
	for my $spec ((map { ['pp.c', $_, 1] } @arithmetic), ['pp_hot.c', 'add', 1],
		(map { ['pp.c', $_, /\A(?:i_)?ncmp\z|\Ascmp\z/ ? 2 : 0] } @comparisons),
		['pp_hot.c', 'eq', 0]) {
		my ($file, $name, $kind) = @$spec;
		my $text = read_file("$source/$file");
		my $marker = "/* Wump scalar operand wrapper: $name */";
		next if index($text, $marker) >= 0;
		$text =~ /^PP\(pp_\Q$name\E\)\n\{/mg or die "$file: missing opcode $name\n";
		my $start = $-[0];
		my $end = index($text, "\n}\n", pos($text));
		$end >= 0 or die "$file: missing end of opcode $name\n";
		$end += 3;
		my $body = substr($text, $start, $end - $start);
		$body =~ s/^PP\(pp_\Q$name\E\)/PP(wump_read_impl_$name)/ or die "$name: rename failed\n";
		my $target = $kind == 1
			? '(PL_op->op_flags & OPf_STACKED) ? PL_stack_sp[-1] : PAD_SV(PL_op->op_targ)'
			: $kind == 2 ? 'PAD_SV(PL_op->op_targ)' : 'NULL';
		$body .= "\n$marker\nPP(pp_$name)\n{\n"
			. "    if (!PL_wump_task) return Perl_wump_read_impl_$name(aTHX);\n"
			. "    SV *target = $target;\n"
			. "    struct wump_operands *guard = Perl_wump_operands_begin(aTHX_ target);\n"
			. "    OP *next = Perl_wump_read_impl_$name(aTHX);\n"
			. "    Perl_wump_operands_end(aTHX_ guard);\n    return next;\n}\n";
		substr($text, $start, $end - $start, $body);
		write_file("$source/$file", $text);
	}
	for my $spec (['pp_hot.c', 'add'], ['pp.c', 'modulo']) {
		my ($file, $name) = @$spec;
		my $text = read_file("$source/$file");
		my $start = index($text, "PP(pp_$name)\n{");
		my $end = index($text, "\n}\n", $start);
		$start >= 0 && $end >= 0 or die "missing numeric entry $name\n";
		my $entry = substr($text, $start, $end + 3 - $start);
		next if index($entry, 'Perl_wump_numeric_enter') >= 0;
		my $fast = "    if (Perl_wump_numeric_enter(aTHX_ target)) {\n"
			. "        OP *next = Perl_wump_write_impl_$name(aTHX);\n"
			. "        Perl_wump_numeric_leave(aTHX);\n        return next;\n    }\n";
		$entry =~ s/^(    struct wump_operands \*guard =)/$fast$1/m
			or die "missing operand guard in numeric entry $name\n";
		substr($text, $start, $end + 3 - $start, $entry);
		write_file("$source/$file", $text);
	}
}
1;
