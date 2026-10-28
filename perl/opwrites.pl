# Wrap audited scalar opcodes at their public entry, before the original
# body tests flags or takes a fast path. Keep the original body intact so
# earlier integration patches remain idempotent.
sub opcode_write_guard {
	my ($source, $file, $name, $target, $extra) = @_;
	my $text = read_file("$source/$file");
	my $marker = "/* Wump scalar opcode wrapper: $name */";
	return if index($text, $marker) >= 0;
	$text =~ /^PP\(pp_\Q$name\E\)\n\{/mg or die "$file: missing opcode $name\n";
	my $start = $-[0];
	my $end = index($text, "\n}\n", pos($text));
	$end >= 0 or die "$file: missing end of opcode $name\n";
	$end += 3;
	my $body = substr($text, $start, $end - $start);
	$body =~ s/^PP\(pp_\Q$name\E\)/PP(wump_write_impl_$name)/ or die "$name: rename failed\n";
	my $second = defined($extra)
		? "    SV *second = $extra;\n    struct wump_mutation *other = second != target ? Perl_wump_mutation_begin(aTHX_ second) : NULL;\n"
		: '';
	my $release = defined($extra) ? "    Perl_wump_mutation_end(aTHX_ other);\n" : '';
	$body .= "\n$marker\nPP(pp_$name)\n{\n"
		. "    if (!PL_wump_task) return Perl_wump_write_impl_$name(aTHX);\n"
		. "    SV *target = $target;\n"
		. "    struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ target);\n"
		. $second
		. "    OP *next = Perl_wump_write_impl_$name(aTHX);\n"
		. $release . "    Perl_wump_mutation_end(aTHX_ guard);\n    return next;\n}\n";
	substr($text, $start, $end - $start, $body);
	write_file("$source/$file", $text);
}

sub apply_opwrites {
	my ($source) = @_;
	for my $spec (['pp_hot.c', 'preinc'], ['pp_hot.c', 'predec'], ['pp.c', 'postinc'], ['pp.c', 'postdec']) {
		my ($file, $name) = @$spec;
		opcode_write_guard($source, $file, $name, '*PL_stack_sp', $name =~ /^post/ ? 'PAD_SV(PL_op->op_targ)' : undef);
	}
	my $binary = '(PL_op->op_flags & OPf_STACKED) ? PL_stack_sp[-1] : PAD_SV(PL_op->op_targ)';
	for my $name (qw(pow multiply divide modulo subtract left_shift right_shift
		bit_and bit_or nbit_and nbit_or sbit_and sbit_or
		i_multiply i_divide i_modulo i_add i_subtract)) {
		opcode_write_guard($source, 'pp.c', $name, $binary);
	}
	for my $name (qw(add concat)) {
		opcode_write_guard($source, 'pp_hot.c', $name, $binary);
	}
	opcode_write_guard($source, 'pp_hot.c', 'sassign',
		'(PL_op->op_private & OPpASSIGN_BACKWARDS) ? PL_stack_sp[-1] : PL_stack_sp[0]');
	opcode_write_guard($source, 'pp_hot.c', 'multiconcat',
		'(PL_op->op_flags & OPf_STACKED) ? ((PL_op->op_private & OPpMULTICONCAT_APPEND)'
		. ' ? PL_stack_sp[-cUNOP_AUXx(PL_op)->op_aux[PERL_MULTICONCAT_IX_NARGS].ssize] : *PL_stack_sp)'
		. ' : PAD_SV(PL_op->op_targ)');
	# This private helper recurses on AV/HV children. Rename only its
	# definition so recursive do_chomp() calls still enter the guard wrapper.
	my $text = read_file("$source/pp.c");
	my $marker = '/* Wump recursive chop/chomp wrapper */';
	if (index($text, $marker) < 0) {
		my $signature = 'S_do_chomp(pTHX_ SV *retval, SV *sv, bool chomping)';
		$text =~ s/\Q$signature\E\n\{/S_wump_do_chomp(pTHX_ SV *retval, SV *sv, bool chomping)\n{/
			or die "missing do_chomp\n";
		my $start = index($text, 'S_wump_do_chomp(');
		my $end = index($text, "\n}\n", $start) + 3;
		substr($text, $end, 0, "\n$marker\nstatic size_t\n$signature\n{\n"
			. "    struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ sv);\n"
			. "    struct wump_mutation *result_guard = retval != sv ? Perl_wump_mutation_begin(aTHX_ retval) : NULL;\n"
			. "    size_t count = S_wump_do_chomp(aTHX_ retval, sv, chomping);\n"
			. "    Perl_wump_mutation_end(aTHX_ result_guard);\n"
			. "    Perl_wump_mutation_end(aTHX_ guard);\n    return count;\n}\n");
		write_file("$source/pp.c", $text);
	}
	edit('pp.c', '    s = SvPV(sv, len);', '    s = SvPV_flags_mutable(sv, len, SV_GMAGIC);');
	for my $name (qw(magic_setsubstr magic_setvec)) {
		memory_guard($source, 'mg.c', $name, 'int', 'LvTARG(sv)');
	}
}
1;
