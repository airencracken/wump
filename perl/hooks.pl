sub apply_hooks {
	my ($source) = @_;
	edit('mg.c', '    SV** svp = NULL;' . "\n    /* Need to be careful", '    SV** svp = NULL;' . "\n    SV **wump_target = NULL;\n    /* Need to be careful");
	edit('mg.c', "            svp = &PL_diehook;", "            svp = (wump_target = sv ? Perl_wump_magic_owned(aTHX_ sv, 'D') : NULL)\n                ? wump_target : &aTHX->Idiehook;");
	edit('mg.c', "&& (sv ? 1 : PL_warnhook != PERL_WARNHOOK_FATAL)", "&& (sv ? 1 : aTHX->Iwarnhook != PERL_WARNHOOK_FATAL)");
	edit('mg.c', "            svp = &PL_warnhook;", "            svp = (wump_target = sv ? Perl_wump_magic_owned(aTHX_ sv, 'W') : NULL)\n                ? wump_target : &aTHX->Iwarnhook;");
	my $mg = read_file("$source/mg.c");
	my $start = index($mg, 'Perl_magic_setsig(');
	my $end = index($mg, 'Perl_magic_setsigall(', $start);
	my $body = substr($mg, $start, $end - $start);
	$body =~ s/\*svp = SvREFCNT_inc_simple_NN\(sv\);/*svp = wump_target ? newSVsv_flags(sv, 0) : SvREFCNT_inc_simple_NN(sv);/g;
	substr($mg, $start, $end - $start, $body);
	write_file("$source/mg.c", $mg);
	edit('regcomp.c', "            if (SvTYPE(gv) == SVt_PVGV && GvSV(gv))\n                save_scalar(gv);", <<'C');
            if (SvTYPE(gv) == SVt_PVGV && GvSV(gv)) {
                if (PL_wump_task) Perl_wump_save_capture(aTHX_ gv);
                else save_scalar(gv);
            }
C
	edit('perlio.c', '                SAVEGENERICSV(PL_warnhook);',
		"                Perl_wump_magic_scope(aTHX_ 'W');\n                SAVEGENERICSV(PL_warnhook);");
	edit('mg.c', 'sv_setiv(sv, (IV)cBOOL(PL_dowarn & G_WARN_ON));',
		'sv_setiv(sv, (IV)cBOOL(*Perl_wump_warning_target(aTHX_ sv) & G_WARN_ON));');
	$mg = read_file("$source/mg.c");
	$start = index($mg, "    case '\\027':", index($mg, 'Perl_magic_set('));
	$end = index($mg, "        else if (strEQ", $start);
	$body = substr($mg, $start, $end - $start);
	$body =~ s/\bPL_dowarn\b/(*Perl_wump_warning_target(aTHX_ sv))/g;
	substr($mg, $start, $end - $start, $body);
	write_file("$source/mg.c", $mg);
	# The outer scope keeps the selected hook alive through conversion and call.
	edit('util.c', "    ENTER;\n    /* sv_2cv might call Perl_croak() or Perl_warner() */",
		"    ENTER;\n    SAVEFREESV(SvREFCNT_inc(oldhook));\n    ENTER;\n    /* sv_2cv might call Perl_croak() or Perl_warner() */");
	edit('util.c', "        LEAVE;\n        return TRUE;\n    }\n    return FALSE;\n}",
		"        LEAVE;\n        LEAVE; /* selected hook */\n        return TRUE;\n    }\n    LEAVE; /* selected hook */\n    return FALSE;\n}");
}
1;
