# UTF-8 methods operate on private source copies with CHECK 0 or 1 in parallel.
# The original encoding object is retained for renewed() callback identity.
sub apply_encode {
	my ($source) = @_;
	my $helpers = <<'C';
static bool
wump_utf8_magic_only(SV *value)
{
    if (SvTYPE(value) < SVt_PVMG) return !SvMAGICAL(value);
    for (MAGIC *magic = SvMAGIC(value); magic; magic = magic->mg_moremagic)
        if (!Perl_wump_publish_magic(magic)) return FALSE;
    return TRUE;
}

static bool
wump_utf8_plain(SV *value)
{
    return SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
        && !SvROK(value) && !SvOBJECT(value) && !SvVALID(value)
        && wump_utf8_magic_only(value);
}

static SV *
wump_utf8_retain(pTHX_ SV *value)
{
    /* A private holder avoids setting TEMP on the retained shared head. */
    SV *holder = sv_2mortal(newSV_type(SVt_IV));
    SvRV_set(holder, SvREFCNT_inc(value));
    SvROK_on(holder);
    return value;
}

static bool
wump_utf8_strict(pTHX_ SV *object)
{
    struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ object);
    if (!SvROK(object) || !wump_utf8_magic_only(object)) {
        Perl_wump_capture_end(aTHX_ capture);
        croak("Wump: parallel UTF-8 conversion requires a plain encoding object");
    }
    SV *hash = wump_utf8_retain(aTHX_ SvRV(object));
    Perl_wump_capture_end(aTHX_ capture);
    capture = Perl_wump_capture_begin(aTHX_ hash);
    if (SvTYPE(hash) != SVt_PVHV || !wump_utf8_magic_only(hash)) {
        Perl_wump_capture_end(aTHX_ capture);
        croak("Wump: parallel UTF-8 conversion requires a plain encoding object");
    }
    SV **slot = hv_fetch((HV *)hash, "strict_utf8", 11, 0);
    SV *value = slot ? wump_utf8_retain(aTHX_ *slot) : NULL;
    Perl_wump_capture_end(aTHX_ capture);
    if (!value) return FALSE;
    capture = Perl_wump_capture_begin(aTHX_ value);
    if (!wump_utf8_plain(value) || (SvOK(value) && !SvIOK(value))) {
        Perl_wump_capture_end(aTHX_ capture);
        croak("Wump: parallel UTF-8 conversion requires a plain integer strictness flag");
    }
    bool strict = SvOK(value) && SvIVX(value) != 0;
    Perl_wump_capture_end(aTHX_ capture);
    return strict;
}

static void
wump_utf8_prepare(pTHX_ SV *object, SV **source, SV **check,
    SV **original, struct wump_mutation **guard)
{
    struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ *check);
    if (!wump_utf8_plain(*check) || (SvOK(*check)
        && (!SvIOK(*check) || (SvIVX(*check) != 0 && SvIVX(*check) != 1)))) {
        Perl_wump_capture_end(aTHX_ capture);
        croak("Wump: parallel UTF-8 conversion requires CHECK 0 or 1");
    }
    IV flags = SvOK(*check) ? SvIVX(*check) : 0;
    Perl_wump_capture_end(aTHX_ capture);
    (void)wump_utf8_strict(aTHX_ object);
    if (flags) {
        *original = *source;
        *guard = Perl_wump_mutation_begin(aTHX_ *original);
    }
    *source = Perl_wump_xs_scalar(aTHX_ *source, "parallel UTF-8 conversion");
    *check = sv_2mortal(newSViv(flags));
}

C
	my $file = "$source/cpan/Encode/Encode.xs";
	my $text = read_file($file);
	my $marker = "static bool\nstrict_utf8(pTHX_ SV* sv)\n{";
	my $at = index($text, $marker);
	$at >= 0 or die "missing UTF-8 strictness helper\n";
	my $old = index($text, "static bool\nwump_utf8_magic_only(");
	if ($old >= 0) { substr($text, $old, $at - $old, $helpers) }
	else { substr($text, $at, 0, $helpers) }
	write_file($file, $text);
	edit('cpan/Encode/Encode.xs', "$marker\n",
		"$marker\n    if (Perl_wump_parallel(aTHX)) return wump_utf8_strict(aTHX_ sv);\n");
	$text = read_file($file);
	for my $name (qw(decode encode)) {
		my $start = index($text, "\nMethod_$name(obj,src,check_sv = &PL_sv_no)\n");
		my $end = index($text, "\nvoid\n", $start);
		$start >= 0 && $end >= 0 or die "missing UTF-8 method $name\n";
		my $entry = substr($text, $start, $end - $start);
		$entry =~ s/^    if \(Perl_wump_parallel\(aTHX\)\) wump_utf8_prepare[^\n]+\n//m;
		$entry =~ s/^PREINIT:\n/PREINIT:\n    SV *wump_original = NULL;\n    struct wump_mutation *wump_guard = NULL;\n/m
			unless index($entry, 'SV *wump_original') >= 0;
		my $prepare = "    if (Perl_wump_parallel(aTHX)) wump_utf8_prepare(aTHX_ obj, &src, &check_sv, &wump_original, &wump_guard);\n";
		$entry =~ s/^INIT:\n/INIT:\n$prepare/m unless index($entry, $prepare) >= 0;
		unless (index($entry, '/* Wump commit consumed source. */') >= 0) {
			$entry =~ s/    ST\(0\) = dst;/    \/\* Wump commit consumed source. \*\/\n    if (wump_original) sv_setsv_flags(wump_original, src, 0);\n    Perl_wump_mutation_end(aTHX_ wump_guard);\n    SPAGAIN;\n    ST(0) = dst;/ or die "missing UTF-8 result $name\n";
		}
		substr($text, $start, $end - $start, $entry);
	}
	write_file($file, $text);
	edit('cpan/Encode/Encode.xs', "BOOT:\n{\n", <<'XS');
BOOT:
{
    if (!PL_wump_task) {
        Perl_wump_xs_allow(aTHX_ get_cv("Encode::utf8::encode", 0));
        Perl_wump_xs_allow(aTHX_ get_cv("Encode::utf8::decode", 0));
    }
XS
}
1;
