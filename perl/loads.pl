# Retain ordinary shared elements before their container read claim ends.
# Existing lvalues keep their original heads. The later materialization pass
# handles missing lvalues and autovivification; magic and overlays keep their
# existing paths. Strong ordinary scalar/aggregate RVs retain their referents.
sub apply_loads {
	my ($source) = @_;
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	if (index($text, '/* Wump container-to-stack loads */') >= 0) {
		apply_lvalue_loads($source);
		apply_reference_loads($source);
		apply_scalar_reference_loads($source);
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
	apply_reference_loads($source);
	apply_scalar_reference_loads($source);
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
sub apply_reference_loads {
	my ($source) = @_;
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	my $marker = '/* Wump aggregate reference loads */';
	return if index($text, $marker) >= 0;
	my $start = index($text, "PP(pp_rv2av)\n{");
	$start >= 0 or die "missing rv2av opcode\n";
	my $at = index($text, '    SvGETMAGIC(sv);', $start);
	$at >= 0 or die "missing rv2av magic anchor\n";
	my $capture = <<'C';
    /* Wump reference capture: rv2av */
    if (PL_wump_task && !(PL_op->op_flags & OPf_MOD && PL_op->op_private & OPpLVAL_INTRO)) {
        bool handled;
        SV *loaded = Perl_wump_load_rv(aTHX_ sv, type, &handled);
        if (handled) { sv = loaded; goto wump_aggregate_loaded; }
    }
    /* End Wump reference capture */
C
	substr($text, $at, 0, $capture);
	$at = index($text, '    if (PL_op->op_flags & OPf_REF) {', $start);
	$at >= 0 or die "missing rv2av aggregate anchor\n";
	substr($text, $at, 0, "  wump_aggregate_loaded:\n");
	for my $kind ('AV', 'HV') {
		for my $vivify (0, 1) {
			my $anchor = $vivify ? "            sv = vivify_ref(sv, OPpDEREF_$kind);"
				: "        do_${kind}_rv2" . lc($kind) . "_aelem:";
			$anchor =~ s/_aelem:/_helem:/ if $kind eq 'HV' && !$vivify;
			$at = index($text, $anchor);
			$at >= 0 or die "missing $kind reference anchor: $anchor\n";
			$at += length($anchor) + 1 unless $vivify;
			my $label = $kind eq 'AV' ? 'do_AV_aelem' : 'do_HV_helem';
			$capture = "            /* Wump reference capture: multideref $kind $vivify */\n"
				. "            if (PL_wump_task) {\n                bool handled;\n"
				. "                SV *loaded = Perl_wump_load_rv(aTHX_ sv, SVt_PV$kind, &handled);\n"
				. "                if (handled) { sv = loaded; goto $label; }\n            }\n"
				. "            /* End Wump reference capture */\n";
			substr($text, $at, 0, $capture);
		}
	}
	write_file($file, "$marker\n$text");
}
sub apply_scalar_reference_loads {
	my ($source) = @_;
	my $file = "$source/pp.c";
	my $text = read_file($file);
	my $marker = '/* Wump scalar reference loads */';
	return if index($text, $marker) >= 0;
	my $start = index($text, "PP(pp_rv2sv)\n{");
	$start >= 0 or die "missing rv2sv opcode\n";
	my $at = index($text, '    SvGETMAGIC(sv);', $start);
	$at >= 0 or die "missing rv2sv magic anchor\n";
	my $capture = <<'C';
    /* Wump reference capture: rv2sv */
    if (PL_wump_task && !(PL_op->op_flags & OPf_MOD && PL_op->op_private & OPpLVAL_INTRO)) {
        bool handled;
        SV *loaded = Perl_wump_load_rv(aTHX_ sv, SVt_PV, &handled);
        if (handled) { sv = loaded; goto wump_scalar_loaded; }
    }
    /* End Wump reference capture */
C
	substr($text, $at, 0, $capture);
	$at = index($text, '    if (PL_op->op_flags & OPf_MOD) {', $start);
	$at >= 0 or die "missing rv2sv lvalue anchor\n";
	substr($text, $at, 0, "  wump_scalar_loaded:\n");
	write_file($file, "$marker\n$text");
}
1;
