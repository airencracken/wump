# Keep the KW_LOCAL grammar and tables; its integer value selects pocket.
sub apply_pocket {
	my ($source) = @_;
	edit('op.h', "    U8\t\top_private;", "    U8\t\top_private;\t\t\\\n    U8          op_wump_pocket;");
	edit('op.h', '#define OP_LVALUE_NO_CROAK 1', "#define OP_LVALUE_NO_CROAK 1\n#define OP_LVALUE_WUMP_POCKET 2");
	edit('toke.c', "    case KEY_local:\n        OPERATOR(KW_LOCAL);",
		"    case KEY_local:\n        pl_yylval.ival = 0;\n        OPERATOR(KW_LOCAL);");
	edit('toke.c', '    /* Check for plugged-in keyword */', <<'C');
    /* Wump syntax is lexical: qualified names and fat-comma keys above
     * retain ordinary name lookup, and code without use Wump is unchanged. */
    if (memEQs(PL_tokenbuf, len, "pocket") && PL_expect != XOPERATOR
            && PL_expect != XREF && PL_hintgv && GvHV(PL_hintgv)) {
        SV **enabled = hv_fetchs(GvHV(PL_hintgv), "Wump/pocket", 0);
        if (enabled && SvTRUE(*enabled)) {
            pl_yylval.ival = 2;
            CLINE;
            OPERATOR(KW_LOCAL);
        }
    }
    /* Check for plugged-in keyword */
C
	edit('perly.y', '{ $$ = localize($operand,0); }', '{ $$ = localize($operand,$KW_LOCAL); }');
	edit('perly.act', '{ (yyval.opval) = localize((ps[0].val.opval),0); }',
		'{ (yyval.opval) = localize((ps[0].val.opval),(ps[-1].val.ival)); }');
	edit('op.c', "Perl_localize(pTHX_ OP *o, I32 lex)\n{", <<'C');
Perl_localize(pTHX_ OP *o, I32 lex)
{
    const bool wump_pocket = lex == 2;
    if (wump_pocket) lex = 0;
C
	edit('op.c', 'o = op_lvalue(o, OP_NULL);',
		'o = Perl_op_lvalue_flags(aTHX_ o, OP_NULL, wump_pocket ? OP_LVALUE_WUMP_POCKET : 0);');
	edit('op.c', "        case 1:\n            o->op_private |= OPpLVAL_INTRO;",
		"        case 1:\n            o->op_wump_pocket = !!(flags & OP_LVALUE_WUMP_POCKET);\n            o->op_private |= OPpLVAL_INTRO;");
	edit('op.c', "        case -1:\n            ck_warner(packWARN(WARN_SYNTAX),",
		"        case -1:\n            if (flags & OP_LVALUE_WUMP_POCKET)\n                croak(\"Wump: unsupported pocket target\");\n            ck_warner(packWARN(WARN_SYNTAX),");
	edit('op.c', 'op_lvalue(sib, type);', 'Perl_op_lvalue_flags(aTHX_ sib, type, flags);');
	edit('op.c', '          local_refgen:',
		"          local_refgen:\n            if (flags & OP_LVALUE_WUMP_POCKET)\n                croak(\"Wump: pocket reference alias localization is not supported yet\");");
	edit('peep.c', '            mderef = newUNOP_AUX(OP_MULTIDEREF, 0, NULL, arg_buf);',
		"            mderef = newUNOP_AUX(OP_MULTIDEREF, 0, NULL, arg_buf);\n            mderef->op_wump_pocket = index_skip == -1 ? o->op_wump_pocket : 0;");
	edit('peep.c', '                    op_null(o->op_next);' . "\n" . '                    o->op_private |= o->op_next->op_private & (OPpLVAL_INTRO',
		'                    op_null(o->op_next);' . "\n" . '                    o->op_wump_pocket = o->op_next->op_wump_pocket;' . "\n" . '                    o->op_private |= o->op_next->op_private & (OPpLVAL_INTRO');
	for my $spec ([scalar => 'GV *gv'], [ary => 'GV *gv'], [hash => 'GV *gv'], [gp => 'GV *gv, I32 empty']) {
		my ($name, $args) = @$spec;
		my $start = "Perl_save_$name(pTHX_ $args)\n{";
		edit('scope.c', $start, "$start\n    if (!PL_wump_task && PL_op && PL_op->op_wump_pocket)\n        croak(\"Wump: pocket requires a running task\");");
	}
	edit('ext/B/B.xs', "MODULE = B\tPACKAGE = B::OP\n", <<'XS');
MODULE = B	PACKAGE = B::OP

U8
wump_pocket(o)
	B::OP o
    CODE:
	RETVAL = o->op_wump_pocket;
    OUTPUT:
	RETVAL
XS
	edit('lib/B/Deparse.pm', '    return $name if $name =~ /^CORE::/; # just in case',
		"    return \$name if \$name eq 'pocket'; # lexical Wump keyword\n    return \$name if \$name =~ /^CORE::/; # just in case");
	edit('lib/B/Deparse.pm', 'push @our_local, "local" if $priv & $lval_intro;',
		'push @our_local, ($op->wump_pocket ? "pocket" : "local") if $priv & $lval_intro;');
	edit('lib/B/Deparse.pm', '$self->keyword("local"). " ";',
		'$self->keyword($op->wump_pocket ? "pocket" : "local"). " ";');
	edit('lib/B/Deparse.pm', 'my $newlocal = "local " x !!($loppriv & OPpLVAL_INTRO) . "our";',
		'my $newlocal = ($lop->wump_pocket ? "pocket " : "local ") x !!($loppriv & OPpLVAL_INTRO) . "our";');
	edit('lib/B/Deparse.pm', <<'OLD', <<'NEW');
	    ($local = "", last) if $local !~ /^(?:either|local)$/;
	    $local = "local";
OLD
	    my $newlocal = $lop->wump_pocket ? 'pocket' : 'local';
	    ($local = "", last) if $local ne 'either' && $local ne $newlocal;
	    $local = $newlocal;
NEW
}
1;
