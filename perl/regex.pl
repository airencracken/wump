sub apply_regex {
	my ($source) = @_;
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
