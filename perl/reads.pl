sub apply_reads {
	my ($source) = @_;
	for my $kind (qw(IV UV NV)) {
		for my $nomg ('', '_nomg') {
			my $name = "Sv$kind$nomg";
			my $flags = $nomg ? '0' : 'SV_GMAGIC';
			my $signature = "Perl_$name(pTHX_ SV *sv) {";
			edit('sv_inline.h', $signature,
				"$signature\n    if (PL_wump_task) return Perl_wump_cache_" . lc($kind) . "(aTHX_ sv, $flags);");
		}
	}
	for my $spec (
		['Perl_SvTRUE(pTHX_ SV *sv)', 'SV_GMAGIC', 'TRUE'],
		['Perl_SvTRUE_nomg(pTHX_ SV *sv)', '0', 'TRUE'],
		['Perl_SvTRUE_NN(pTHX_ SV *sv)', 'SV_GMAGIC', 'TRUE'],
		['Perl_SvTRUE_common(pTHX_ SV * sv, const bool sv_2bool_is_fallback)', '0', 'sv_2bool_is_fallback'],
	) {
		my ($signature, $flags, $fallback) = @$spec;
		edit('sv_inline.h', "$signature\n{",
			"$signature\n{\n    if (PL_wump_task) return Perl_wump_cache_truth(aTHX_ sv, $flags, $fallback);");
	}
	edit('sv.c', '#define PERL_IN_SV_C', "#define PERL_IN_SV_C\n/* Shared scalar reads use private conversion storage. */");
	# All function prototypes are available through the generated private header.
	edit('sv.c', '#include "perl.h"', "#include \"perl.h\"\n#include \"wump_reads.c\"");
	for my $kind (qw(iv uv nv bool)) {
		my $signature = $kind eq 'bool'
			? 'Perl_sv_2bool_flags(pTHX_ SV *sv, I32 flags)'
			: "Perl_sv_2${kind}_flags(pTHX_ SV *const sv, const I32 flags)";
		my $old = "$signature\n{\n    if (Perl_wump_readable(aTHX_ sv)) return Perl_wump_read_$kind(aTHX_ sv, flags);";
		my $new = $kind eq 'bool' ? $old
			: "$signature\n{\n    if (!(flags & SV_MUTABLE_RETURN) && Perl_wump_readable(aTHX_ sv)) return Perl_wump_read_$kind(aTHX_ sv, flags);";
		my $text = read_file("$source/sv.c");
		if (index($text, $new) < 0 && $text =~ s/\Q$old\E/$new/) { write_file("$source/sv.c", $text) }
		edit('sv.c', "$signature\n{", $new);
	}
	for my $spec (
		['Perl_sv_2pv_flags(pTHX_ SV *const sv, STRLEN *const lp, const U32 flags)', 0],
		['Perl_sv_2pvbyte_flags(pTHX_ SV *sv, STRLEN *const lp, const U32 flags)', 1],
		['Perl_sv_2pvutf8_flags(pTHX_ SV *sv, STRLEN *const lp, const U32 flags)', 2],
	) {
		my ($signature, $encoding) = @$spec;
		edit('sv.c', "$signature\n{", "$signature\n{\n    if (!(flags & SV_MUTABLE_RETURN) && Perl_wump_readable(aTHX_ sv))\n        return Perl_wump_read_pv(aTHX_ sv, lp, flags, $encoding);");
	}
	edit('sv.c', '    PERL_ARGS_ASSERT_SV_SETSV_FLAGS;',
		"    PERL_ARGS_ASSERT_SV_SETSV_FLAGS;\n    if (dsv != ssv && Perl_wump_readable(aTHX_ ssv)) {\n        Perl_wump_read_copy(aTHX_ dsv, ssv, flags);\n        return;\n    }");
	# Explicit writers need the original buffer installed on the original SV.
	edit('sv.c', '            (void) sv_2pv_flags(sv,&len, flags);',
		'            (void) sv_2pv_flags(sv,&len, flags | SV_MUTABLE_RETURN);');
	edit('sv.c', '        s = sv_2pv_flags(sv, &len, flags &~ SV_GMAGIC);',
		'        s = sv_2pv_flags(sv, &len, (flags &~ SV_GMAGIC) | SV_MUTABLE_RETURN);');
	edit('sv.c', "Perl_report_uninit(pTHX_ const SV *uninit_sv)\n{",
		"Perl_report_uninit(pTHX_ const SV *uninit_sv)\n{\n    uninit_sv = Perl_wump_read_origin(aTHX_ uninit_sv);");
	edit('perl.c', '    init_constants();', "    aTHX->Iwump_read_frame = NULL;\n    init_constants();");
	edit('sv.c', "    aTHX->Iwump_keys_ready = TRUE;",
		"    aTHX->Iwump_keys_ready = TRUE;\n    aTHX->Iwump_read_frame = NULL;");
}
1;
