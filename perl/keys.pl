sub apply_keys {
	my ($source) = @_;
	edit('perl.c', "    PL_curcop = &PL_compiling;\t/* needed by ckWARN, right away */",
		"    PL_curcop = &PL_compiling;\t/* needed by ckWARN, right away */\n    if (!aTHX->Iwump_keys_ready) {\n        MUTEX_INIT(&aTHX->Iwump_keys_mutex);\n        aTHX->Iwump_keys_ready = TRUE;\n    }");
	edit('perl.c', "    if (PL_veto_cleanup)\n        return;",
		"    if (PL_veto_cleanup)\n        return;\n    if (aTHX->Iwump_keys_ready) {\n        MUTEX_DESTROY(&aTHX->Iwump_keys_mutex);\n        aTHX->Iwump_keys_ready = FALSE;\n    }");
	edit('sv.c', '    INIT_TRACK_MEMPOOL(my_perl->Imemory_debug_header, my_perl);',
		"    INIT_TRACK_MEMPOOL(my_perl->Imemory_debug_header, my_perl);\n    MUTEX_INIT(&aTHX->Iwump_keys_mutex);\n    aTHX->Iwump_keys_ready = TRUE;");
	my $header = read_file("$source/hv.h");
	$header =~ s/#define share_hek_hek\(hek\).*?(?=\n#define hv_store_ent)/#define share_hek_hek(hek) Perl_wump_hek_retain(hek)\n/s
		or die "missing shared key retain macro\n";
	write_file("$source/hv.h", $header);
	edit('hv.c', "void\nPerl_unsharepvn(pTHX_ const char *str, I32 len, U32 hash)",
		"#include \"wump_keys.c\"\n\nvoid\nPerl_unsharepvn(pTHX_ const char *str, I32 len, U32 hash)");
	my $hash = read_file("$source/hv.c");
	for my $spec (
		['STATIC HEK *', 'S_share_hek_flags(pTHX_ const char *str, STRLEN len, U32 hash, int flags)',
			'return wump_share_key(aTHX_ str, len, hash, flags);'],
		['STATIC void', 'S_unshare_hek_or_pvn(pTHX_ const HEK *hek, const char *str, I32 len, U32 hash)',
			'wump_unshare_key(aTHX_ hek, str, len, hash);'],
	) {
		my ($type, $signature, $body) = @$spec;
		$hash =~ s/\Q$type\E\n\Q$signature\E\n\{.*?\n\}/$type\n$signature\n{\n    $body\n}/s
			or die "missing shared key function $signature\n";
	}
	write_file("$source/hv.c", $hash);
}
1;
