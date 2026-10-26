sub apply_publication {
	my ($source) = @_;
	edit('sv.c', '    if (UNLIKELY( ssv == dsv ))',
		"    Perl_wump_publish_reference(aTHX_ dsv, ssv);\n    if (UNLIKELY( ssv == dsv ))");
	edit('sv.c', "Perl_sv_setrv_noinc(pTHX_ SV *const sv, SV *const ref)\n{",
		"Perl_sv_setrv_noinc(pTHX_ SV *const sv, SV *const ref)\n{\n    Perl_wump_publish_store(aTHX_ sv, ref);");
	edit('sv.c', "    SvFLAGS(nsv) |= SVTYPEMASK;\t\t/* Mark as freed */",
		"    Perl_wump_publish_refresh(aTHX_ sv);\n    SvFLAGS(nsv) |= SVTYPEMASK;\t\t/* Mark as freed */");
	# Element overlays intercept these operations before the base aggregate's
	# magic. Publish only base stores; fresh localized cells stay private.
	edit('av.c', "    PERL_ARGS_ASSERT_AV_STORE;",
		"    Perl_wump_publish_store(aTHX_ (SV *)av, val);\n    PERL_ARGS_ASSERT_AV_STORE;");
	my $hash = read_file("$source/hv.c");
	$hash =~ s/(\s+val = newSV_type\(SVt_NULL\);)(?!\n\s+Perl_wump_publish_store)/$1\n                    Perl_wump_publish_store(aTHX_ (SV *)hv, val);/g;
	write_file("$source/hv.c", $hash);
	edit('sv.c', "            mg_get(ssv);\n            if (SvTYPE(ssv) != stype)",
		"            mg_get(ssv);\n            Perl_wump_publish_reference(aTHX_ dsv, ssv);\n            if (SvTYPE(ssv) != stype)");
}
1;
