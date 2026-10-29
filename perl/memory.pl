sub memory_guard {
	my ($source, $file, $name, $type, $value, $condition, $second) = @_;
	my $text = read_file("$source/$file");
	my $marker = "/* Wump mutation wrapper: $name */";
	return if index($text, $marker) >= 0;
	$text =~ /^(Perl_\Q$name\E\([^;]*?\))\n\{/mg or die "$file: missing $name\n";
	my $signature = $1;
	my $start = $-[1];
	my $end = index($text, "\n}\n", pos($text));
	$end >= 0 or die "$file: missing end of $name\n";
	$end += 3;
	my $body = substr($text, $start, $end - $start);
	my $params = $signature;
	$params =~ s/^Perl_\Q$name\E\(pTHX_\s*// or die "$name: missing pTHX\n";
	$params =~ s/\)\z//;
	my @args = map { /\b(\w+)\s*\z/ ? $1 : die "$name: unsupported argument $_\n" } split /,/, $params;
	@args = map { $_ eq 'ptr' ? 'Perl_wump_mutation_pointer(aTHX_ guard, ptr)' : $_ } @args if $name eq 'sv_chop';
	my $begin = "Perl_wump_mutation_begin(aTHX_ (SV *)$value)";
	$begin = "($condition) ? $begin : NULL" if defined $condition;
	my $call = "wump_memory_impl_$name(aTHX_ " . join(', ', @args) . ')';
	my $invoke = $type eq 'void' ? "$call;" : "$type result = $call;";
	my $return = $type eq 'void' ? '' : "\n    return result;";
	my $extra = defined($second) ? "    SV *second = $second;\n"
		. "    struct wump_mutation *other = second != (SV *)$value ? Perl_wump_mutation_begin(aTHX_ second) : NULL;\n" : '';
	my $release = defined($second) ? "    Perl_wump_mutation_end(aTHX_ other);\n" : '';
	$body = "#define Perl_$name wump_memory_impl_$name\n$body#undef Perl_$name\n\n"
		. "$marker\n$type\n$signature\n{\n    struct wump_mutation *guard = $begin;\n$extra    $invoke\n$release    Perl_wump_mutation_end(aTHX_ guard);$return\n}\n";
	substr($text, $start, $end - $start, $body);
	write_file("$source/$file", $text);
}

sub apply_memory {
	my ($source) = @_;
	# COW aliases can belong to different values/executors. The byte counter
	# must be atomic, and a splitting owner keeps its reference until after
	# copying bytes so another final drop cannot free the source underneath it.
	edit('sv.h', '#   define CowREFCNT(sv)' . "\t" . '(*(U8 *)(SvPVX(sv)+SvLEN(sv)-1))',
		'#   define CowREFCNT(sv) __atomic_load_n((U8 *)(SvPVX(sv)+SvLEN(sv)-1), __ATOMIC_ACQUIRE)');
	for my $indent ('                    ', '        ') {
		edit('sv.c', "\n" . $indent . 'CowREFCNT(ssv) = 0;',
			"\n" . $indent . '__atomic_store_n((U8 *)(SvPVX(ssv)+SvLEN(ssv)-1), 0, __ATOMIC_RELEASE);');
	}
	edit('op.c', 'CowREFCNT(sv) = 0;', '__atomic_store_n((U8 *)(SvPVX(sv)+SvLEN(sv)-1), 0, __ATOMIC_RELEASE);');
	edit('sv.c', '&& CowREFCNT(ssv) != SV_COW_REFCNT_MAX', '&& Perl_wump_cow_retain(aTHX_ ssv)');
	edit('sv.c', '                    CowREFCNT(ssv)++;',
		'                    if (!(sflags & SVf_IsCOW)) (void)Perl_wump_cow_retain(aTHX_ ssv);');
	edit('sv.c', '        assert(CowREFCNT(ssv) < SV_COW_REFCNT_MAX);', '        /* The atomic retain below handles saturation. */');
	edit('sv.c', '    CowREFCNT(ssv)++;', <<'C');
    if (!Perl_wump_cow_retain(aTHX_ ssv)) {
        SvPV_set(dsv, NULL);
        SvLEN_set(dsv, 0);
        SvCUR_set(dsv, 0);
        sv_setsv_flags(dsv, ssv, SV_NOSTEAL | SV_COW_SHARED_HASH_KEYS);
        return dsv;
    }
C
	edit('sv.c', "Perl_sv_setsv_cow(pTHX_ SV *dsv, SV *ssv)\n{", <<'C');
Perl_sv_setsv_cow(pTHX_ SV *dsv, SV *ssv)
{
    if ((dsv && Perl_wump_is_shared(aTHX_ dsv)) || Perl_wump_is_shared(aTHX_ ssv)) {
        if (!dsv) dsv = newSV(0);
        sv_setsv_flags(dsv, ssv, SV_NOSTEAL | SV_COW_SHARED_HASH_KEYS);
        return dsv;
    }
C
	edit('sv.c', '        const bool was_shared_hek = SvIsCOW_shared_hash(sv);',
		"        const bool was_shared_hek = SvIsCOW_shared_hash(sv);\n        bool wump_release_cow = FALSE;");
	edit('sv.c', "                    cowrefcnt--;\n                    CowREFCNT(sv) = cowrefcnt;",
		'                    wump_release_cow = TRUE;');
	edit('sv.c', '            if (was_shared_hek) {', <<'C');
            if (wump_release_cow
                && __atomic_fetch_sub((U8 *)(pvx + len - 1), 1, __ATOMIC_ACQ_REL) == 0)
                Safefree((char *)pvx);
            if (was_shared_hek) {
C
	edit('sv.c', "                        if (CowREFCNT(sv)) {\n                            sv_buf_to_rw(sv);\n                            CowREFCNT(sv)--;",
		"                        sv_buf_to_rw(sv);\n                        if (__atomic_fetch_sub((U8 *)(SvPVX(sv)+SvLEN(sv)-1), 1, __ATOMIC_ACQ_REL) != 0) {");
	edit('sv.c', "#define plant_SV(p) \\\n    STMT_START {",
		"#define plant_SV(p) \\\n    STMT_START { \\\n        Perl_wump_memory_forget(aTHX_ (SV *)(p));");
	edit('sv.c', '    return my_perl;', "    Perl_wump_memory_clone(aTHX);\n    return my_perl;");
	edit('sv.c', "perl_clone(PerlInterpreter *proto_perl, UV flags)\n{",
		"perl_clone(PerlInterpreter *proto_perl, UV flags)\n{\n    Perl_wump_memory_clone_check(proto_perl);");
	for my $spec (
		['sv.c', 'wump_storage_sv.c'], ['av.c', 'wump_storage_av.c'], ['hv.c', 'wump_storage_hv.c'],
	) {
		my ($file, $include) = @$spec;
		my $text = read_file("$source/$file");
		$text .= "\n#include \"$include\"\n" unless index($text, "#include \"$include\"") >= 0;
		write_file("$source/$file", $text);
	}
	for my $name (qw(sv_setiv sv_setuv sv_setnv sv_setpvn sv_setpv sv_usepvn_flags
		sv_setrv_noinc sv_setrv_inc sv_set_undef sv_set_true sv_set_false sv_set_bool
		sv_chop sv_upgrade sv_force_normal_flags sv_setiv_mg sv_setuv_mg sv_setnv_mg
		sv_setpvn_mg sv_setpv_mg sv_setrv_noinc_mg sv_setrv_inc_mg)) {
		memory_guard($source, 'sv.c', $name, 'void', 'sv');
	}
	for my $name (qw(sv_inc sv_inc_nomg sv_dec sv_dec_nomg sv_utf8_encode sv_replace)) {
		memory_guard($source, 'sv.c', $name, 'void', 'sv');
	}
	for my $name (qw(sv_utf8_downgrade_flags sv_utf8_decode)) {
		memory_guard($source, 'sv.c', $name, 'bool', 'sv');
	}
	for my $spec (['iv', 'IV'], ['uv', 'UV'], ['nv', 'NV']) {
		my ($name, $type) = @$spec;
		memory_guard($source, 'sv.c', "sv_2${name}_flags", $type, 'sv', 'flags & SV_MUTABLE_RETURN');
	}
	edit('sv.c', '            s = (U8 *) SvPV_flags(sv, len, mg_flags);',
		'            s = (U8 *) SvPV_flags_mutable(sv, len, mg_flags);');
	edit('sv.c', '        (void) SvIV(sv);', '        (void) sv_2iv_flags(sv, SV_GMAGIC | SV_MUTABLE_RETURN);');
	for my $name (qw(sv_catpvn_flags sv_catsv_flags)) {
		memory_guard($source, 'sv.c', $name, 'void', 'dsv');
	}
	memory_guard($source, 'sv.c', 'sv_setsv_mg', 'void', 'dsv', 'dsv != ssv');
	memory_guard($source, 'sv.c', 'sv_catpv', 'void', 'dsv');
	memory_guard($source, 'sv.c', 'sv_catpv_mg', 'void', 'dsv');
	memory_guard($source, 'sv.c', 'sv_insert_flags', 'void', 'bigstr');
	memory_guard($source, 'sv.c', 'sv_setsv_flags', 'void', 'dsv', 'dsv != ssv');
	memory_guard($source, 'sv.c', 'sv_grow', 'char *', 'sv');
	memory_guard($source, 'sv.c', 'sv_grow_fresh', 'char *', 'sv');
	memory_guard($source, 'sv.c', 'sv_pvn_force_flags', 'char *', 'sv');
	memory_guard($source, 'sv.c', 'sv_utf8_upgrade_flags_grow', 'STRLEN', 'sv');
	memory_guard($source, 'sv.c', 'sv_2pv_flags', 'char *', 'sv', 'flags & SV_MUTABLE_RETURN');
	for my $name (qw(av_extend av_store av_clear av_undef av_push av_pop av_unshift av_shift av_fill av_delete av_fetch)) {
		my $type = $name eq 'av_store' || $name eq 'av_fetch' ? 'SV **'
			: $name eq 'av_pop' || $name eq 'av_shift' || $name eq 'av_delete' ? 'SV *' : 'void';
		memory_guard($source, 'av.c', $name, $type, 'av', $name eq 'av_fetch' ? 'lval' : undef);
	}
	memory_guard($source, 'hv.c', 'hv_common', 'void *', 'hv', 'action & (HV_FETCH_ISSTORE | HV_FETCH_LVALUE | HV_DELETE)');
	for my $name (qw(hv_clear hv_undef_flags hv_ksplit)) {
		memory_guard($source, 'hv.c', $name, 'void', 'hv');
	}
	# Deferred delegates mutate their own target fields as well as looking up
	# or creating a cell. Keep the container claim through the ownership handoff.
	memory_guard($source, 'mg.c', 'defelem_target', 'SV *', 'sv', undef,
		'LvTARGLEN(sv) ? LvTARG(sv) : NULL');
	memory_guard($source, 'mg.c', 'vivify_defelem', 'void', 'sv', undef,
		'LvTARGLEN(sv) ? LvTARG(sv) : NULL');
	for my $name (qw(magic_getdefelem magic_setdefelem)) {
		memory_guard($source, 'mg.c', $name, 'int', 'sv');
	}
	memory_guard($source, 'pp_hot.c', 'vivify_ref', 'SV *', 'sv');
	# Route ordinary PV macros through a protected capture. Mutable access
	# remains a writer API. Explicit byte/UTF-8 conversions retain snapshots.
	my $header = read_file("$source/sv.h");
	my @macros = (
		['SvPV_flags(sv, len, flags)', 'Perl_wump_pv(aTHX_ (sv), &(len), (flags))'],
		['SvPV_flags_const(sv, len, flags)', '((const char *)Perl_wump_pv(aTHX_ (sv), &(len), (flags) | SV_CONST_RETURN))'],
		['SvPV_flags_const_nolen(sv, flags)', '((const char *)Perl_wump_pv(aTHX_ (sv), NULL, (flags) | SV_CONST_RETURN))'],
		['SvPV_nolen(sv)', 'Perl_wump_pv(aTHX_ (sv), NULL, SV_GMAGIC)'],
		['SvPV_nomg_nolen(sv)', 'Perl_wump_pv(aTHX_ (sv), NULL, 0)'],
	);
	for my $encoding (['byte', 1], ['utf8', 2]) {
		my ($name, $kind) = @$encoding;
		for my $form ('', '_nomg', '_nolen', '_or_null', '_or_null_nomg') {
			my $length = $form eq '_nolen' ? 'NULL' : '&(len)';
			my $flags = $form =~ /nomg/ ? '0' : 'SV_GMAGIC';
			my $null = $form =~ /or_null/ ? 'TRUE' : 'FALSE';
			my $macro = "SvPV$name$form(sv" . ($length eq 'NULL' ? ')' : ', len)');
			push @macros, [$macro, "Perl_wump_pv_encoded(aTHX_ (sv), $length, $flags, $kind, $null)"];
		}
	}
	for my $spec (@macros) {
		my ($macro, $replacement) = @$spec;
		my $start = index($header, "#define $macro");
		$start >= 0 or die "missing $macro\n";
		my $end = index($header, "\n", $start);
		while (substr($header, $end - 1, 1) eq '\\') { $end = index($header, "\n", $end + 1) }
		substr($header, $start, $end - $start, "#define $macro $replacement");
	}
	write_file("$source/sv.h", $header);
}
1;
