# Admit individual native entries only after auditing their implementation in
# the pinned Perl source. Blocking calls and process-wide mutations stay gated.
sub apply_xs {
	my ($source) = @_;
	require "$FindBin::Bin/mro.pl";
	apply_mro($source);
	# The HAS_GETCWD path uses a local buffer and the caller's private XS
	# target. Other Cwd helpers use different native/context paths. Never
	# admit the fallback implementation which walks by changing process cwd.
	edit('dist/PathTools/Cwd.xs', "BOOT:\n", <<'XS');
BOOT:
#ifdef HAS_GETCWD
    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv("Cwd::getcwd", 0));
#endif
XS
	edit('dist/PathTools/Cwd.xs', "#ifdef HAS_GETCWD\n    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv(\"Cwd::getcwd\", 0));\n#endif\n", <<'XS');
#ifdef HAS_GETCWD
    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv("Cwd::getcwd", 0));
#endif
    if (!PL_wump_task) {
        Perl_wump_xs_allow(aTHX_ get_cv("File::Spec::Unix::canonpath", 0));
        Perl_wump_xs_allow(aTHX_ get_cv("File::Spec::Unix::_fn_canonpath", 0));
    }
XS
	# Canonicalization uses local buffers and returns a new scalar. Snapshot
	# plain input before native string coercion; leave other path helpers gated.
	edit('dist/PathTools/Cwd.xs', "    STRLEN plen;\n    SvGETMAGIC(path);", <<'XS');
    STRLEN plen;
    if (Perl_wump_parallel(aTHX)) {
        struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ path);
        bool plain = SvTYPE(path) <= SVt_PVMG && SvTYPE(path) != SVt_INVLIST
            && !SvROK(path) && !SvOBJECT(path) && !SvVALID(path);
        if (plain && SvTYPE(path) >= SVt_PVMG) {
            MAGIC *magic;
            for (magic = SvMAGIC(path); magic; magic = magic->mg_moremagic) {
                if (!Perl_wump_publish_magic(magic)) { plain = FALSE; break; }
            }
        }
        if (!plain) {
            Perl_wump_capture_end(aTHX_ capture);
            croak("Wump: parallel path canonicalization requires a plain scalar");
        }
        SV *copy = sv_mortalcopy(path);
        Perl_wump_capture_end(aTHX_ capture);
        path = copy;
    }
    SvGETMAGIC(path);
XS
	# The functional join entries have no method dispatch. Their native join
	# loop reads scalar flags directly, so snapshot every argument and avoid
	# the module's shared MY_CXT constants for the whole call.
	my $path_snapshot = <<'XS';
static SV *
wump_unix_path_snapshot(pTHX_ SV *path)
{
    struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ path);
    bool plain = SvTYPE(path) <= SVt_PVMG && SvTYPE(path) != SVt_INVLIST
        && !SvVALID(path);
    if (plain && SvTYPE(path) >= SVt_PVMG) {
        MAGIC *magic;
        for (magic = SvMAGIC(path); magic; magic = magic->mg_moremagic) {
            if (!Perl_wump_publish_magic(magic)) { plain = FALSE; break; }
        }
    }
    if (!plain) {
        Perl_wump_capture_end(aTHX_ capture);
        croak("Wump: parallel path joining requires a plain scalar or reference");
    }
    /* A Mojo::File child can pass the blessed scalar's stored value itself.
     * Copy value caches into an unblessed private head without COW writes to
     * the source. References retain their referent for later coercion. */
    SV *copy = sv_2mortal(newSV_type(SVt_PVNV));
    if (SvROK(path)) {
        sv_setrv_inc(copy, SvRV(path));
    } else if (SvIsBOOL(path)) {
        sv_setsv(copy, boolSV(SvTRUE_nomg(path)));
    } else {
        U32 flags = SvFLAGS(path);
        if (SvPOKp(path))
            sv_setpvn(copy, SvPVX_const(path) ? SvPVX_const(path) : "", SvCUR(path));
        if (SvIOKp(path)) {
            if (SvIsUV(path)) SvUV_set(copy, SvUVX(path));
            else SvIV_set(copy, SvIVX(path));
        }
        if (SvNOKp(path)) SvNV_set(copy, SvNVX(path));
        const U32 cache = SVf_IOK | SVp_IOK | SVf_NOK | SVp_NOK
            | SVf_POK | SVp_POK | SVf_IVisUV | SVf_UTF8;
        SvFLAGS(copy) = (SvFLAGS(copy) & ~cache) | (flags & cache);
    }
    Perl_wump_capture_end(aTHX_ capture);
    return copy;
}

static SV *
wump_unix_path_text(pTHX_ SV *copy)
{
    /* String conversion may call Perl overloads, throw or park. The RV is
     * private and retains the original referent; no capture spans a callback. */
    if (!SvOK(copy)) return copy;
    STRLEN length;
    const char *bytes = SvPV(copy, length);
    SV *text = sv_2mortal(newSVpvn(bytes, length));
    if (SvUTF8(copy)) SvUTF8_on(text);
    return text;
}

#define unix_canonpath(p) THX_unix_canonpath(aTHX_ p)
XS
	my $cwd_file = "$source/dist/PathTools/Cwd.xs";
	my $cwd_text = read_file($cwd_file);
	my $helper_start = index($cwd_text, "static SV *\nwump_unix_path_snapshot(");
	my $macro = "#define unix_canonpath(p) THX_unix_canonpath(aTHX_ p)\n";
	my $macro_start = index($cwd_text, $macro, $helper_start >= 0 ? $helper_start : 0);
	$macro_start >= 0 or die "missing path canonicalizer macro\n";
	$helper_start = $macro_start if $helper_start < 0;
	substr($cwd_text, $helper_start, $macro_start + length($macro) - $helper_start, $path_snapshot);
	for my $name (qw(_fn_catfile _fn_catdir)) {
		my $start = index($cwd_text, "\n$name(...)\n");
		my $end = index($cwd_text, "\nOUTPUT:\n    RETVAL", $start);
		$start >= 0 && $end >= 0 or die "missing functional path entry $name\n";
		my $entry = substr($cwd_text, $start, $end - $start);
		$entry =~ s{^CODE:\n    /\* Wump private join arguments and constants\. \*/\n.*?^    \}\n}{CODE:\n}ms;
		$entry =~ s/\bEMPTY_STRING_SV\b/wump_empty/g;
		$entry =~ s/\bSLASH_STRING_SV\b/wump_slash/g;
		my $prepare = <<'XS';
CODE:
    /* Wump private join arguments and constants. */
    SV *wump_empty, *wump_slash;
    struct wump_mutation **wump_guards = NULL;
    if (Perl_wump_parallel(aTHX)) {
        wump_empty = sv_2mortal(newSVpvs(""));
        wump_slash = sv_2mortal(newSVpvs("/"));
        for (I32 i = 0; i < items; i++) {
            ST(i) = wump_unix_path_snapshot(aTHX_ ST(i));
            if (SvROK(ST(i))) {
                if (!wump_guards) {
                    Newxz(wump_guards, items, struct wump_mutation *);
                    SAVEFREEPV((char *)wump_guards);
                }
                /* Overloads can expose their actual argument RV. Publish
                 * and claim this copy before any conversion callback. */
                Perl_wump_publish(aTHX_ ST(i));
                wump_guards[i] = Perl_wump_mutation_begin(aTHX_ ST(i));
            }
        }
        SPAGAIN;
    } else {
        wump_empty = EMPTY_STRING_SV;
        wump_slash = SLASH_STRING_SV;
    }
XS
		$entry =~ s/^CODE:\n/$prepare/m or die "missing path entry body $name\n";
		$entry =~ s/wump_unix_path_snapshot\(aTHX_ ST\(items-1\), TRUE\)/wump_unix_path_text(aTHX_ ST(items-1))/g;
		if ($name eq '_fn_catfile' && index($entry, 'ST(items-1) = wump_unix_path_text') < 0) {
			$entry =~ s/\tSV \*file = unix_canonpath\(ST\(items-1\)\);/\tif (Perl_wump_parallel(aTHX)) {\n            ST(items-1) = wump_unix_path_text(aTHX_ ST(items-1));\n            SPAGAIN;\n        }\n\tSV *file = unix_canonpath(ST(items-1));/
				or die "missing final path component\n";
		}
		unless (index($entry, '/* Wump release path claims. */') >= 0) {
			$entry .= <<'XS';

    /* Wump release path claims. */
    if (wump_guards) {
        for (I32 i = items; i-- > 0;)
            Perl_wump_mutation_end(aTHX_ wump_guards[i]);
    }
XS
		}
		$entry =~ s/\n+\z//;
		substr($cwd_text, $start, $end - $start, $entry);
	}
	write_file($cwd_file, $cwd_text);
	edit('dist/PathTools/Cwd.xs', "        Perl_wump_xs_allow(aTHX_ get_cv(\"File::Spec::Unix::_fn_canonpath\", 0));\n    }\n", <<'XS');
        Perl_wump_xs_allow(aTHX_ get_cv("File::Spec::Unix::_fn_canonpath", 0));
    }
    if (!PL_wump_task) {
        Perl_wump_xs_allow(aTHX_ get_cv("File::Spec::Unix::_fn_catfile", 0));
        Perl_wump_xs_allow(aTHX_ get_cv("File::Spec::Unix::_fn_catdir", 0));
    }
XS
	# On the supported Linux build these entries call gettimeofday or
	# clock_gettime/getres with stack-local output and allocate only their
	# return values. They do not modify Time::HiRes's interpreter context.
	edit('dist/Time-HiRes/HiRes.xs', "BOOT:\n    {\n", <<'XS');
BOOT:
    {
        /* Wump audited clock entries; register before acts start. */
        if (!PL_wump_task) {
            const char *names[] = {
                "Time::HiRes::time", "Time::HiRes::gettimeofday",
                "Time::HiRes::clock_gettime", "Time::HiRes::clock_getres"
            };
            for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
                CV *entry = get_cv(names[i], 0);
                if (entry) Perl_wump_xs_allow(aTHX_ entry);
            }
        }
XS
	# NFC/NFD and their aliases use immutable generated tables and local
	# buffers. Keep input flags and storage private for the whole operation.
	edit('dist/Unicode-Normalize/Normalize.xs', "    STRLEN len;\n    s = SvPV(sv,len);", <<'XS');
    STRLEN len;
    if (Perl_wump_parallel(aTHX)) {
        struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ sv);
        bool plain = SvTYPE(sv) <= SVt_PVMG && SvTYPE(sv) != SVt_INVLIST
            && !SvROK(sv) && !SvOBJECT(sv) && !SvVALID(sv);
        if (plain && SvTYPE(sv) >= SVt_PVMG) {
            MAGIC *magic;
            for (magic = SvMAGIC(sv); magic; magic = magic->mg_moremagic) {
                if (!Perl_wump_publish_magic(magic)) { plain = FALSE; break; }
            }
        }
        if (!plain) {
            Perl_wump_capture_end(aTHX_ capture);
            croak("Wump: parallel Unicode normalization requires a plain scalar");
        }
        SV *copy = sv_mortalcopy(sv);
        Perl_wump_capture_end(aTHX_ capture);
        sv = copy;
    }
    s = SvPV(sv,len);
XS
	edit('dist/Unicode-Normalize/Normalize.xs', "    if (lp)\n\t*lp = len;", <<'XS');
    if (Perl_wump_parallel(aTHX) && !is_utf8_string((const U8 *)s, len))
        croak("Wump: parallel Unicode normalization requires well-formed UTF-8");
    if (lp)
	*lp = len;
XS
	edit('dist/Unicode-Normalize/Normalize.xs', "MODULE = Unicode::Normalize\tPACKAGE = Unicode::Normalize\n", <<'XS');
MODULE = Unicode::Normalize	PACKAGE = Unicode::Normalize

BOOT:
    if (!PL_wump_task) {
        /* Aliases share these audited native entries: NFKC/FCC and NFKD. */
        Perl_wump_xs_allow(aTHX_ get_cv("Unicode::Normalize::NFC", 0));
        Perl_wump_xs_allow(aTHX_ get_cv("Unicode::Normalize::NFD", 0));
    }
XS
}
1;
