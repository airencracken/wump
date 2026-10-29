# Admit individual native entries only after auditing their implementation in
# the pinned Perl source. Blocking calls and process-wide mutations stay gated.
sub apply_xs {
	my ($source) = @_;
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
