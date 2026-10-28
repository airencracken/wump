# Source adaptations for ordinary array/hash element overlays.
sub apply_elements {
	my ($source) = @_;
	edit('av.h', "#define AvFILL(av)\t((SvRMAGICAL((const SV *) (av))) \\\n                         ? mg_size(MUTABLE_SV(av)) : AvFILLp(av))",
		"#define AvFILL(av)\tPerl_wump_av_fill((AV *)(av))");
	edit('hv.h', "#define HvUSEDKEYS(hv)\t\t(HvTOTALKEYS(hv) - HvPLACEHOLDERS_get(hv))",
		"#ifdef PERL_IN_HV_C\n#define HvUSEDKEYS(hv)\t\t(HvTOTALKEYS(hv) - HvPLACEHOLDERS_get(hv))\n#else\n#define HvUSEDKEYS(hv) Perl_wump_hv_used((HV *)(hv))\n#endif");
	for my $name ('fetch', 'store', 'exists') {
		my $signature = $name eq 'fetch' ? 'I32 lval' : $name eq 'store' ? 'SV *val' : '';
		my $start = "Perl_av_$name(pTHX_ AV *av, SSize_t key" . ($signature ? ", $signature" : '') . ")\n{";
		my $hook = "\n    bool wump_handled;\n    SV **wump_slot = Perl_wump_av_slot(aTHX_ av, &key, " . ($name eq 'fetch' ? 'lval' : $name eq 'store' ? 'TRUE' : 'FALSE') . ", &wump_handled);\n";
		$hook .= $name eq 'store' ? <<'C' : $name eq 'fetch' ? "    if (wump_handled) return wump_slot;\n" : "    if (wump_handled) return wump_slot != NULL;\n";
    if (wump_handled) {
        if (!wump_slot) return NULL;
        SV *old = *wump_slot;
        *wump_slot = val;
        SvREFCNT_dec(old);
        return wump_slot;
    }
C
		edit('av.c', $start, "$start$hook");
	}
	for my $spec (
		['av.c', 'Perl_av_clear(pTHX_ AV *av)', 'av'],
		['av.c', 'Perl_av_undef(pTHX_ AV *av)', 'av'],
		['av.c', 'Perl_av_fill(pTHX_ AV *av, SSize_t fill)', 'av'],
		['av.c', 'Perl_av_delete(pTHX_ AV *av, SSize_t key, I32 flags)', 'av'],
		['av.c', 'Perl_av_push(pTHX_ AV *av, SV *val)', 'av'],
		['av.c', 'Perl_av_pop(pTHX_ AV *av)', 'av'],
		['av.c', 'Perl_av_shift(pTHX_ AV *av)', 'av'],
		['av.c', 'Perl_av_unshift(pTHX_ AV *av, SSize_t num)', 'av'],
		['hv.c', 'Perl_hv_clear(pTHX_ HV *hv)', 'hv'],
		['hv.c', 'Perl_hv_undef_flags(pTHX_ HV *hv, U32 flags)', 'hv'],
	) {
		my ($file, $signature, $arg) = @$spec;
		edit($file, "$signature\n{", "$signature\n{\n    Perl_wump_element_structure(aTHX_ (SV *)$arg);");
	}
	edit('hv.c', '    if (action & HV_DELETE) {', <<'C');
    void *wump_result;
    if (Perl_wump_hv_slot(aTHX_ hv, key, klen, flags | (is_utf8 ? HVhek_UTF8 : 0),
            action, val, hash, &wump_result)) return wump_result;
    if (action & HV_DELETE) {
C
	edit('hv.c', "Perl_hv_iterinit(pTHX_ HV *hv)\n{",
		"Perl_hv_iterinit(pTHX_ HV *hv)\n{\n    HV *wump_view = Perl_wump_hv_iteration(aTHX_ hv, TRUE);\n    if (wump_view != hv) return hv_iterinit(wump_view);");
	edit('hv.c', "Perl_hv_iternext_flags(pTHX_ HV *hv, I32 flags)\n{",
		"Perl_hv_iternext_flags(pTHX_ HV *hv, I32 flags)\n{\n    hv = Perl_wump_hv_iteration(aTHX_ hv, FALSE);");
	edit('hv.c', '    if (wump_view != hv) return hv_iterinit(wump_view);',
		"    if (wump_view != hv) return hv_iterinit(wump_view);\n    I32 wump_count;\n    if (Perl_wump_hv_iter_reset(aTHX_ hv, &wump_count)) return wump_count;");
	edit('hv.c', '    hv = Perl_wump_hv_iteration(aTHX_ hv, FALSE);',
		"    hv = Perl_wump_hv_iteration(aTHX_ hv, FALSE);\n    bool wump_iter_handled;\n    HE *wump_entry = Perl_wump_hv_iter_next(aTHX_ hv, flags, &wump_iter_handled);\n    if (wump_iter_handled) return wump_entry;");
	# Native cloning must avoid saving/restoring the source's root cursor.
	edit('hv.c', '    if (!SvMAGICAL((const SV *)ohv)) {',
		'    if (!SvMAGICAL((const SV *)ohv) || Perl_wump_hv_readable(aTHX_ ohv)) {');
	edit('hv.c', '    u = HvUSEDKEYS(hv);', '    u = Perl_wump_hv_used(hv);');
	edit('hv.c', '        Size_t nkeys = HvUSEDKEYS(hv);',
		'        Size_t nkeys = Perl_wump_hv_used(hv);');
	edit('hv.c', "Perl_newHVhv(pTHX_ HV *ohv)\n{",
		"Perl_newHVhv(pTHX_ HV *ohv)\n{\n    HV *wump_copy = Perl_wump_hv_clone(aTHX_ ohv);\n    if (wump_copy) return wump_copy;");
	for my $file ('pp.c', 'pp_hot.c') {
		my $text = read_file("$source/$file");
		# These branches previously installed stock save-stack entries. Task
		# bindings already own their scope callbacks before lvalue lookup.
		for my $op ($file eq 'pp.c' ? qw(aslice hslice) : qw(aelem helem multideref)) {
			my $start = index($text, "PP(pp_$op)\n{");
			$start >= 0 or die "$file: missing pp_$op\n";
			my $end = index($text, "\n}\n", $start) + 3;
			$end > $start or die "$file: missing end of pp_$op\n";
			my $body = substr($text, $start, $end - $start);
			unless (index($body, 'Perl_wump_local_av(') >= 0 || index($body, 'Perl_wump_local_hv(') >= 0) {
				$body =~ s/if \((?:UNLIKELY\()?localizing\)?\)/if (localizing \&\& !PL_wump_task)/g;
				$body =~ s/if \(localizing && can_preserve\)/if (localizing \&\& can_preserve \&\& !PL_wump_task)/g;
				$body =~ s/if \(lval && localizing\)/if (lval \&\& localizing \&\& !PL_wump_task)/g;
				$body =~ s/av_fetch\(av, elem, (lval(?: && !defer)?)\)/(localizing \&\& PL_wump_task ? Perl_wump_local_av(aTHX_ av, elem) : av_fetch(av, elem, $1))/g;
				$body =~ s/hv_fetch_ent\(hv, keysv, (lval(?: && !defer)?), 0\)/(localizing \&\& PL_wump_task ? Perl_wump_local_hv(aTHX_ hv, keysv) : hv_fetch_ent(hv, keysv, $1, 0))/g;
				substr($text, $start, $end - $start, $body);
			}
		}
		write_file("$source/$file", $text);
	}
	# splice and the bulk push implementation can write AvARRAY directly.
	edit('pp.c', "    AV * const ary = MUTABLE_AV(*++MARK);",
		"    AV * const ary = MUTABLE_AV(*++MARK);\n    Perl_wump_element_structure(aTHX_ (SV *)ary);");
	my $pp = read_file("$source/pp.c");
	$pp =~ s/\Q    AV *ary = MUTABLE_AV(*++MARK);\E(?!\n    Perl_wump_element_structure)/    AV *ary = MUTABLE_AV(*++MARK);\n    Perl_wump_element_structure(aTHX_ (SV *)ary);/g;
	write_file("$source/pp.c", $pp);
	edit('pp.c', '            av = MUTABLE_AV((*SP));',
		"            av = MUTABLE_AV((*SP));\n            Perl_wump_element_structure(aTHX_ (SV *)av);");
	edit('pp_sort.c', '        av = MUTABLE_AV((*PL_stack_sp));',
		"        av = MUTABLE_AV((*PL_stack_sp));\n        Perl_wump_element_structure(aTHX_ (SV *)av);");
	for my $spec (['aelem', 'AV', 'av'], ['helem', 'HV', 'hv']) {
		my ($name, $type, $arg) = @$spec;
		my $signature = "S_localise_${name}_lval(pTHX_ $type * const $arg, SV * const keysv,\n                            const bool can_preserve)\n{";
		edit('pp.c', $signature, "$signature\n    if (PL_wump_task) croak(\"Wump: reference alias localization in a task is not supported yet\");");
	}
}
1;
