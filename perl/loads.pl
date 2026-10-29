# Retain ordinary shared elements before their container read claim ends.
# Existing lvalues keep their original heads; magic, overlays, missing lvalues
# and autovivification keep their existing paths.
sub apply_loads {
	my ($source) = @_;
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	if (index($text, '/* Wump container-to-stack loads */') >= 0) {
		apply_lvalue_loads($source);
		return;
	}
	for my $spec (
		['aelemfast', '    assert(SvTYPE(av) == SVt_PVAV);', <<'C'],
    if (PL_wump_task && !lval) {
        bool handled;
        sv = Perl_wump_load_av(aTHX_ av, key, &handled);
        if (handled) goto ret;
    }
C
		['aelem', '    if (UNLIKELY(SvTYPE(av) != SVt_PVAV)) {', <<'C'],
    if (PL_wump_task && !lval) {
        bool handled;
        retsv = Perl_wump_load_av(aTHX_ av, elem, &handled);
        if (handled) goto ret;
    }
C
		['helem', '    if (SvTYPE(hv) != SVt_PVHV) {', <<'C'],
    if (PL_wump_task && !lval) {
        bool handled;
        retsv = Perl_wump_load_hv(aTHX_ hv, keysv, &handled);
        if (handled) goto ret;
    }
C
	) {
		my ($name, $anchor, $insert) = @$spec;
		$text =~ /^PP\(pp_\Q$name\E\)\n\{/mg or die "missing load opcode $name\n";
		my $start = $-[0];
		my $end = index($text, "\n}\n", pos($text));
		my $at = index($text, $anchor, $start);
		$at >= 0 && $at < $end or die "missing $name load anchor\n";
		substr($text, $at, 0, $insert);
	}
	for my $spec (
		['                    SV** svp = av_fetch((AV*)sv, elem, 1);', <<'C'],
                    if (PL_wump_task) {
                        bool handled;
                        SV *loaded = Perl_wump_load_av(aTHX_ (AV *)sv, elem, &handled);
                        if (handled && loaded != &PL_sv_undef) { sv = loaded; break; }
                    }
C
		['                    HE *he = hv_fetch_ent((HV*)sv, keysv, 1, 0);', <<'C'],
                    if (PL_wump_task) {
                        bool handled;
                        SV *loaded = Perl_wump_load_hv(aTHX_ (HV *)sv, keysv, &handled);
                        if (handled && loaded != &PL_sv_undef) { sv = loaded; break; }
                    }
C
		['                    AV *const av = (AV*)sv;', <<'C'],
                    if (PL_wump_task && !lval) {
                        bool handled;
                        SV *loaded = Perl_wump_load_av(aTHX_ (AV *)sv, elem, &handled);
                        if (handled) { sv = loaded; goto finish; }
                    }
C
		['                    HV * const hv = (HV*)sv;', <<'C'],
                    if (PL_wump_task && !lval) {
                        bool handled;
                        SV *loaded = Perl_wump_load_hv(aTHX_ (HV *)sv, keysv, &handled);
                        if (handled) { sv = loaded; goto finish; }
                    }
C
	) {
		my ($anchor, $insert) = @$spec;
		my $at = index($text, $anchor);
		$at >= 0 or die "missing multideref load anchor: $anchor\n";
		substr($text, $at, 0, $insert);
	}
	$text .= "\n/* Wump container-to-stack loads */\n";
	write_file($file, $text);
	apply_lvalue_loads($source);
}

sub apply_lvalue_loads {
	my ($source) = @_;
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	my $marker = '/* Wump existing lvalue loads */';
	return if index($text, $marker) >= 0;
	# Upgrade sources which already have the read-only load patch. Never jump
	# past localization/vivification side effects, or turn a missing lvalue into
	# the immortal undef scalar. Existing real undef heads remain valid aliases.
	for my $spec (
		['    ', 'sv', 'av, key', 'av', 'ret', ''],
		['    ', 'retsv', 'av, elem', 'av', 'ret', ' && !localizing && !(PL_op->op_private & OPpDEREF)'],
		['    ', 'retsv', 'hv, keysv', 'hv', 'ret', ' && !localizing && !(PL_op->op_private & OPpDEREF)'],
		['                    ', 'loaded', '(AV *)sv, elem', 'av', 'finish', ' && !localizing'],
		['                    ', 'loaded', '(HV *)sv, keysv', 'hv', 'finish', ' && !localizing'],
	) {
		my ($indent, $result, $args, $kind, $label, $condition) = @$spec;
		my $declaration = $result eq 'loaded' ? 'SV *' : '';
		my $tail = $result eq 'loaded' ? "{ sv = loaded; goto $label; }" : "goto $label;";
		my $old = "${indent}if (PL_wump_task && !lval) {\n"
			. "${indent}    bool handled;\n"
			. "${indent}    $declaration$result = Perl_wump_load_$kind(aTHX_ $args, &handled);\n"
			. "${indent}    if (handled) $tail\n${indent}}";
		my $new = $old;
		$new =~ s/PL_wump_task && !lval/PL_wump_task$condition/;
		$new =~ s/if \(handled\)/if (handled \&\& (!lval || $result != \&PL_sv_undef))/;
		my $at = index($text, $old);
		$at >= 0 or die "missing existing-lvalue load anchor: $kind $args\n";
		substr($text, $at, length($old), $new);
	}
	$text .= "\n$marker\n";
	write_file($file, $text);
}
1;
