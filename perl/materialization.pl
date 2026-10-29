# Apply after the original element/reference patches. Prefix markers keep
# older patch upgrades idempotent even when their end markers are recreated.
sub apply_materialization {
	my ($source) = @_;
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	my $marker = '/* Wump lvalue materialization */';
	if (index($text, $marker) < 0) {
		for my $spec (
			['aelemfast', 'sv', 'av, key', 'av', 'FALSE'],
			['aelem', 'retsv', 'av, elem', 'av', 'defer'],
			['helem', 'retsv', 'hv, keysv', 'hv', 'defer'],
		) {
			my ($name, $result, $args, $kind, $defer) = @$spec;
			$text =~ /^PP\(pp_\Q$name\E\)\n\{/mg or die "missing materialization opcode $name\n";
			my $start = $-[0];
			my $end = index($text, "\n}\n", pos($text)) + 3;
			my $body = substr($text, $start, $end - $start);
			$body =~ s/PL_wump_task && !localizing && !\(PL_op->op_private & OPpDEREF\)/PL_wump_task \&\& !localizing/ if $name ne 'aelemfast';
			my $call = "$result = Perl_wump_load_$kind(aTHX_ $args, &handled);";
			my $replacement = "$result = lval ? Perl_wump_lvalue_$kind(aTHX_ $args, $defer, &handled)\n"
				. "            : Perl_wump_load_$kind(aTHX_ $args, &handled);";
			$body =~ s/\Q$call\E/$replacement/ or die "missing $name lvalue call\n";
			my $old = "if (handled && (!lval || $result != &PL_sv_undef)) goto ret;";
			my $finish = $name eq 'aelemfast' ? 'if (handled) goto ret;'
				: "if (handled) {\n            if (lval && (PL_op->op_private & OPpDEREF))\n"
				. "                $result = vivify_ref($result, PL_op->op_private & OPpDEREF);\n            goto ret;\n        }";
			$body =~ s/\Q$old\E/$finish/ or die "missing $name lvalue finish\n";
			substr($text, $start, $end - $start, $body);
		}
		for my $kind ('av', 'hv') {
			my $cast = uc($kind);
			my $key = $kind eq 'av' ? 'elem' : 'keysv';
			my $old = "SV *loaded = Perl_wump_load_$kind(aTHX_ ($cast *)sv, $key, &handled);";
			# The first occurrence is the intermediate (always creating) load.
			my $at = index($text, $old);
			$at >= 0 or die "missing intermediate $kind load\n";
			substr($text, $at, length($old), "SV *loaded = Perl_wump_lvalue_$kind(aTHX_ ($cast *)sv, $key, FALSE, &handled);");
			# The remaining occurrence is the final read/lvalue load.
			$at = index($text, $old);
			$at >= 0 or die "missing final $kind load\n";
			my $new = "SV *loaded = lval ? Perl_wump_lvalue_$kind(aTHX_ ($cast *)sv, $key, defer, &handled)\n"
				. "                            : Perl_wump_load_$kind(aTHX_ ($cast *)sv, $key, &handled);";
			substr($text, $at, length($old), $new);
			my $finish = 'if (handled && (!lval || loaded != &PL_sv_undef)) { sv = loaded; goto finish; }';
			$at = index($text, $finish, $at);
			$at >= 0 or die "missing final $kind finish\n";
			substr($text, $at, length($finish), 'if (handled) { sv = loaded; goto finish; }');
		}
		# Existing non-task execution keeps the upstream preparation path.
		my $old = "        prepare_SV_for_RV(sv);\n        switch (to_what) {";
		my $at = index($text, $old);
		$at >= 0 or die "missing vivify preparation\n";
		substr($text, $at, 0, "        if (PL_wump_task) Perl_wump_vivify_value(aTHX_ sv, to_what);\n        else {\n");
		$old = "        SvROK_on(sv);\n        SvSETMAGIC(sv);";
		$at = index($text, $old, $at);
		$at >= 0 or die "missing vivify commit\n";
		substr($text, $at, length($old), "        SvROK_on(sv);\n        }\n        SvSETMAGIC(sv);");
		write_file($file, "$marker\n$text");
	}

	$file = "$source/mg.c";
	$text = read_file($file);
	$marker = '/* Wump deferred ownership commit */';
	if (index($text, $marker) < 0) {
		# Commit the delegate's new fields before dropping old owners, whose
		# destructors can reenter Perl. A nonextendible miss still releases AV.
		my $old = "            LvTARG(sv) = NULL;\t/* array can't be extended */";
		my $at = index($text, $old);
		$at >= 0 or die "missing nonextendible deferred branch\n";
		substr($text, $at, length($old), "            NOOP; /* no value; common commit releases the old array */");
		$old = "    SvREFCNT_inc_simple_void(value);\n    SvREFCNT_dec(LvTARG(sv));\n"
			. "    LvTARG(sv) = value;\n    LvTARGLEN(sv) = 0;\n"
			. "    SvREFCNT_dec(mg->mg_obj);\n    mg->mg_obj = NULL;\n    mg->mg_flags &= ~MGf_REFCOUNTED;";
		my $new = "    SV *old_target = LvTARG(sv), *old_key = mg->mg_obj;\n"
			. "    LvTARG(sv) = SvREFCNT_inc(value);\n    LvTARGLEN(sv) = 0;\n"
			. "    mg->mg_obj = NULL;\n    mg->mg_flags &= ~MGf_REFCOUNTED;\n"
			. "    SvREFCNT_dec(old_target);\n    SvREFCNT_dec(old_key);";
		$at = index($text, $old);
		$at >= 0 or die "missing deferred ownership transfer\n";
		substr($text, $at, length($old), $new);
		$old = "            SvREFCNT_dec(LvTARG(sv));\n            LvTARG(sv) = SvREFCNT_inc_simple_NN(targ);\n"
			. "            LvTARGLEN(sv) = 0;\n            SvREFCNT_dec(mg->mg_obj);\n"
			. "            mg->mg_obj = NULL;\n            mg->mg_flags &= ~MGf_REFCOUNTED;";
		$new = "            SV *old_target = LvTARG(sv), *old_key = mg->mg_obj;\n"
			. "            LvTARG(sv) = SvREFCNT_inc_simple_NN(targ);\n            LvTARGLEN(sv) = 0;\n"
			. "            mg->mg_obj = NULL;\n            mg->mg_flags &= ~MGf_REFCOUNTED;\n"
			. "            SvREFCNT_dec(old_target);\n            SvREFCNT_dec(old_key);";
		$at = index($text, $old);
		$at >= 0 or die "missing deferred existing-target transfer\n";
		substr($text, $at, length($old), $new);
		write_file($file, "$marker\n$text");
	}
}
1;
