sub apply_regex {
	my ($source) = @_;
	# Bare qr values need no compiler. Admission and ownership happen before
	# the original native bare-pattern path can call the subject's magic.
	edit('pp_ctl.c', "PP(pp_regcomp)\n", <<'C');
EXTCONST regexp_engine PL_core_reg_engine;

STATIC REGEXP *
S_wump_precompiled_regex(pTHX_ SV *input, SV *owner)
{
    struct wump_borrow *head = Perl_wump_capture_begin(aTHX_ input);
    struct wump_borrow *body = NULL;
    struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
    bool valid = !SvGMAGICAL(input) && !SvWEAKREF(input) && !SvTAINTED(input);
    SV *value = input;
    if (valid && SvROK(input)) {
        value = SvRV(input);
        body = Perl_wump_capture_begin(aTHX_ value);
    }
    valid = valid && SvTYPE(value) == SVt_REGEXP && !SvTAINTED(value);
    if (valid) {
        MAGIC *magic;
        for (magic = SvMAGIC(value); magic; magic = magic->mg_moremagic) {
            if (!Perl_wump_publish_magic(magic)) { valid = FALSE; break; }
        }
    }
    if (valid && SvOBJECT(value)) {
        HV *stash = SvSTASH(value);
        const char *name = HvNAME_get(stash);
        valid = name && strEQ(name, "Regexp") && !Gv_AMG(stash);
    }
    if (valid) {
        REGEXP *rx = (REGEXP *)value;
        valid = RX_ENGINE(rx) == &PL_core_reg_engine
            && !(RX_EXTFLAGS(rx) & RXf_EVAL_SEEN);
    }
    if (valid) sv_setrv_inc(owner, value);
    Perl_wump_mutation_end(aTHX_ guard);
    Perl_wump_capture_end(aTHX_ body);
    Perl_wump_capture_end(aTHX_ head);
    if (!valid)
        croak("Wump: runtime compilation is not supported during parallel execution");
    return (REGEXP *)SvRV(owner);
}

PP(pp_regcomp)
C
	edit('pp_ctl.c', "    bool is_bare_re= FALSE;\n", <<'C');
    bool is_bare_re= FALSE;
    SV *wump_pattern_owner = NULL;
    SSize_t wump_args_index = 0;
C
	my $regcomp = read_file("$source/pp_ctl.c");
	my $start = index($regcomp, "PP(pp_regcomp)\n");
	my $native = index($regcomp, "    /* prevent recompiling under /o and ithreads. */\n", $start);
	$start >= 0 && $native >= 0 or die "missing native regex compilation entry\n";
	my $admission = index($regcomp, "    if (Perl_wump_parallel(aTHX)) {\n", $start);
	$admission = $native if $admission < 0 || $admission > $native;
	# Replace earlier generated admission blocks as well as inserting into a
	# fresh tree. Updating the policy must not retain an older gate before it.
	substr($regcomp, $admission, $native - $admission) = <<'C';
    if (Perl_wump_parallel(aTHX)) {
        if ((pm->op_pmflags & PMf_KEEP) && PM_GETRE(pm)) goto finish;
        if (nargs != 1 || pm->op_code_list || (pm->op_pmflags & PMf_HAS_CV) || TAINT_get)
            croak("Wump: runtime compilation is not supported during parallel execution");
        wump_args_index = args - PL_stack_base;
        wump_pattern_owner = sv_2mortal(newSV_type(SVt_IV));
        new_re = S_wump_precompiled_regex(aTHX_ args[0], wump_pattern_owner);
        re = PM_GETRE(pm);
        is_bare_re = TRUE;
        goto wump_bare_pattern;
    }

C
	write_file("$source/pp_ctl.c", $regcomp);
	edit('pp_ctl.c', "        tmp = reg_temp_copy(NULL, new_re);\n", <<'C');
        if (wump_pattern_owner) re = PM_GETRE(pm);
        tmp = reg_temp_copy(NULL, new_re);
C
	edit('pp_ctl.c', "    rpp_popfree_to_NN(args - 1);\n", <<'C');
    if (wump_pattern_owner) args = PL_stack_base + wump_args_index;
    rpp_popfree_to_NN(args - 1);
C
	edit('pp_ctl.c', "    if (is_bare_re) {\n        REGEXP *tmp;", <<'C');
  wump_bare_pattern:
    if (is_bare_re) {
        REGEXP *tmp;
C
	edit('pp_ctl.c', "        tmp = reg_temp_copy(NULL, new_re);\n        ReREFCNT_dec(new_re);\n", <<'C');
        tmp = reg_temp_copy(NULL, new_re);
        /* Move private ownership to the clone before releasing the source.
         * Subject magic and allocation failures retain an unwind root. */
        if (wump_pattern_owner) SvRV_set(wump_pattern_owner, (SV *)tmp);
        ReREFCNT_dec(new_re);
C
	edit('pp_ctl.c', "        PM_SETRE(pm, new_re);\n    }\n\n\n    assert(TAINTING_get || !TAINT_get);", <<'C');
        PM_SETRE(pm, new_re);
    }
    if (wump_pattern_owner) {
        /* PM_SETRE now owns the clone. */
        SvRV_set(wump_pattern_owner, NULL);
        SvROK_off(wump_pattern_owner);
    }

    assert(TAINTING_get || !TAINT_get);
C
	# Unicode inversion lists are immutable during execution, but searching
	# them updates a last-index hint shared by regexes and case folding. The
	# hint needs no ordering with table contents, only race-free access.
	edit('regcomp_invlist.c', '    return *get_invlist_previous_index_addr(invlist);',
		'    return __atomic_load_n(get_invlist_previous_index_addr(invlist), __ATOMIC_RELAXED);');
	edit('regcomp_invlist.c', '    *get_invlist_previous_index_addr(invlist) = index;',
		'    __atomic_store_n(get_invlist_previous_index_addr(invlist), index, __ATOMIC_RELAXED);');
	# reg_temp_copy already owns its substring descriptor, but ordinarily
	# retains the original BM strings. Their usefulness counters and encoding
	# caches are writable during matching, so parallel acts need private ones.
	if (index(read_file("$source/regcomp.c"), 'S_wump_regex_cache_copy(pTHX_ SV *source)') < 0) {
		edit('regcomp.c', "REGEXP *\nPerl_reg_temp_copy(pTHX_ REGEXP *dsv, REGEXP *ssv)\n", <<'C');
STATIC SV *
S_wump_regex_cache_copy(pTHX_ SV *source)
{
    if (!source || source == &PL_sv_undef) return SvREFCNT_inc(source);
    SV *copy = newSVpvn(SvPVX_const(source) ? SvPVX_const(source) : "", SvCUR(source));
    if (SvUTF8(source)) SvUTF8_on(copy);
    if (SvVALID(source)) {
        U32 flags = SvTAIL(source) ? FBMcf_TAIL : 0;
        /* The stored string already has fbm_compile's tail sentinel. */
        if ((flags & FBMcf_TAIL) && SvCUR(copy)) {
            SvCUR_set(copy, SvCUR(copy) - 1);
            SvPVX(copy)[SvCUR(copy)] = '\0';
        }
        fbm_compile(copy, flags);
        BmUSEFUL(copy) = BmUSEFUL(source);
    }
    return copy;
}

REGEXP *
Perl_reg_temp_copy(pTHX_ REGEXP *dsv, REGEXP *ssv)
C
	}
	edit('regcomp.c', <<'OLD', <<'NEW');
            SvREFCNT_inc_void(drx->substrs->data[i].substr);
            SvREFCNT_inc_void(drx->substrs->data[i].utf8_substr);
OLD
            if (Perl_wump_parallel(aTHX)) {
                drx->substrs->data[i].substr = S_wump_regex_cache_copy(aTHX_ srx->substrs->data[i].substr);
                drx->substrs->data[i].utf8_substr = S_wump_regex_cache_copy(aTHX_ srx->substrs->data[i].utf8_substr);
            } else {
                SvREFCNT_inc_void(drx->substrs->data[i].substr);
                SvREFCNT_inc_void(drx->substrs->data[i].utf8_substr);
            }
NEW
	edit('regcomp.c', <<'OLD', <<'C');
        /* check_substr and check_utf8, if non-NULL, point to either their
           anchored or float namesakes, and don't hold a second reference.  */
    }
    if (srx->logical_to_parno) {
OLD
        if (Perl_wump_parallel(aTHX)) {
            if (srx->check_substr)
                drx->check_substr = drx->substrs->data[srx->check_substr == srx->substrs->data[0].substr ? 0 : 1].substr;
            if (srx->check_utf8)
                drx->check_utf8 = drx->substrs->data[srx->check_utf8 == srx->substrs->data[0].utf8_substr ? 0 : 1].utf8_substr;
        }
        /* check_substr and check_utf8, if non-NULL, point to either their
           anchored or float namesakes, and don't hold a second reference.  */
    }
    if (srx->logical_to_parno) {
C
	memory_guard($source, 'regcomp.c', 'reg_temp_copy', 'REGEXP *', 'ssv',
		'Perl_wump_parallel(aTHX)', undef, 1);
}
1;
