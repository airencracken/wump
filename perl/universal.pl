# Capability lookup owns private input heads and shares the method-cache
# guard with ordinary dispatch. Conversion callbacks run before the guard.
sub apply_universal {
	my ($source) = @_;
	edit('universal.c', 'XS(XS_UNIVERSAL_isa); /* prototype to pass -Wmissing-prototypes */', <<'C');
STATIC SV *S_wump_can_input(pTHX_ SV *value, bool reference);
XS(XS_UNIVERSAL_isa); /* prototype to pass -Wmissing-prototypes */
C
	edit('universal.c', 'XS(XS_UNIVERSAL_can); /* prototype to pass -Wmissing-prototypes */', <<'C');
STATIC SV *
S_wump_can_input(pTHX_ SV *value, bool reference)
{
    struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ value);
    bool plain = SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
        && !SvOBJECT(value) && !SvVALID(value) && (reference || !SvROK(value));
    if (plain && SvTYPE(value) >= SVt_PVMG) {
        MAGIC *magic;
        for (magic = SvMAGIC(value); magic; magic = magic->mg_moremagic) {
            if (!Perl_wump_publish_magic(magic)) { plain = FALSE; break; }
        }
    }
    if (!plain) {
        Perl_wump_capture_end(aTHX_ capture);
        croak("Wump: parallel capability lookup requires a plain scalar or reference");
    }
    SV *copy = sv_mortalcopy(value);
    Perl_wump_capture_end(aTHX_ capture);
    return copy;
}

XS(XS_UNIVERSAL_can); /* prototype to pass -Wmissing-prototypes */
C
	my $file = "$source/universal.c";
	my $text = read_file($file);
	my $isa_start = index($text, "XS(XS_UNIVERSAL_isa)\n{");
	my $isa_end = index($text, "\n}\n", $isa_start);
	$isa_start >= 0 && $isa_end >= 0 or die "missing ancestry query entry\n";
	my $isa = substr($text, $isa_start, $isa_end - $isa_start);
	unless (index($isa, '/* Wump guarded ancestry query. */') >= 0) {
		my $query = <<'C';
        /* Wump guarded ancestry query. */
        if (Perl_wump_parallel(aTHX)) {
            SV *receiver = S_wump_can_input(aTHX_ ST(0), TRUE);
            if (!SvOK(receiver) || !(SvROK(receiver) || (SvPOK(receiver) && SvCUR(receiver))))
                XSRETURN_UNDEF;
            SV *kind = S_wump_can_input(aTHX_ ST(1), FALSE);
            STRLEN length;
            (void)SvPV(kind, length);
            SPAGAIN;
            struct wump_borrow *capture = SvROK(receiver)
                ? Perl_wump_capture_begin(aTHX_ SvRV(receiver)) : NULL;
            struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
            bool derived = sv_derived_from_sv(receiver, kind, 0);
            Perl_wump_mutation_end(aTHX_ guard);
            Perl_wump_capture_end(aTHX_ capture);
            ST(0) = boolSV(derived);
            XSRETURN(1);
        }
        SV * const sv = ST(0);
C
		$isa =~ s/        SV \* const sv = ST\(0\);\n/$query/ or die "missing ancestry inputs\n";
		substr($text, $isa_start, $isa_end - $isa_start, $isa);
		write_file($file, $text);
	}
	my $start = index($text, "XS(XS_UNIVERSAL_can)\n{");
	my $end = index($text, "\n}\n", $start);
	$start >= 0 && $end >= 0 or die "missing capability lookup entry\n";
	my $entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump guarded capability lookup. */') >= 0) {
		$entry =~ s/    sv = ST\(0\);/    \/\* Wump guarded capability lookup. \*\/\n    struct wump_mutation *wump_guard = NULL;\n    SV *wump_method = ST(1);\n    sv = Perl_wump_parallel(aTHX) ? S_wump_can_input(aTHX_ ST(0), TRUE) : ST(0);/
			or die "missing capability receiver\n";
		my $prepare = <<'C';
    if (Perl_wump_parallel(aTHX)) {
        /* Coerce private heads before locking: an undef method can warn,
         * and a warning hook can throw, grow the stack or schedule. */
        STRLEN length;
        if (!SvROK(sv)) (void)SvPV(sv, length);
        wump_method = S_wump_can_input(aTHX_ ST(1), FALSE);
        const char *bytes = SvPV(wump_method, length);
        SV *text = sv_2mortal(newSVpvn(bytes, length));
        if (SvUTF8(wump_method)) SvUTF8_on(text);
        wump_method = text;
        SPAGAIN;
        wump_guard = Perl_wump_metadata_begin(aTHX);
    }

    rv = &PL_sv_undef;
C
		$entry =~ s/    rv = &PL_sv_undef;\n/$prepare/ or die "missing capability lookup body\n";
		$entry =~ s/gv_fetchmethod_sv_flags\(pkg, ST\(1\), 0\)/gv_fetchmethod_sv_flags(pkg, wump_method, 0)/
			or die "missing capability method lookup\n";
		my $result = <<'C';
        if (gv && isGV(gv)) {
            SV *method = MUTABLE_SV(GvCV(gv));
            if (Perl_wump_parallel(aTHX)) {
                Perl_wump_publish(aTHX_ method);
                /* newRV clears the referent's TEMP bit. This head belongs
                 * to the shared method cache; keep its flags untouched. */
                rv = sv_2mortal(newSV_type(SVt_IV));
                sv_setrv_inc(rv, method);
            } else {
                rv = sv_2mortal(newRV(method));
            }
        }
C
		$entry =~ s/        if \(gv && isGV\(gv\)\)\n            rv = sv_2mortal\(newRV\(MUTABLE_SV\(GvCV\(gv\)\)\)\);\n/$result/
			or die "missing capability return reference\n";
		$entry =~ s/    ST\(0\) = rv;/    Perl_wump_mutation_end(aTHX_ wump_guard);\n    ST(0) = rv;/
			or die "missing capability return\n";
		substr($text, $start, $end - $start, $entry);
		write_file($file, $text);
	}
	$text = read_file($file);
	$start = index($text, "XS(XS_utf8_downgrade)\n{");
	$end = index($text, "\n}\n", $start);
	$start >= 0 && $end >= 0 or die "missing UTF-8 downgrade entry\n";
	$entry = substr($text, $start, $end - $start);
	{
		$entry =~ s{        /\* Wump guarded byte downgrade\. \*/\n.*?(?=        SV \* const sv0 = ST\(0\);)}{}s;
		my $downgrade = <<'C';
        /* Wump guarded byte downgrade. */
        if (Perl_wump_parallel(aTHX)) {
            SV *value = ST(0);
            SV *flag = items < 2 ? &PL_sv_no
                : Perl_wump_xs_scalar(aTHX_ ST(1), "parallel byte downgrade flag");
            bool failok = SvTRUE(flag);
            struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ value);
            bool plain = SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
                && !SvROK(value) && !SvOBJECT(value) && !SvVALID(value);
            if (plain && SvTYPE(value) == SVt_PVMG) {
                for (MAGIC *magic = SvMAGIC(value); magic; magic = magic->mg_moremagic)
                    if (!Perl_wump_publish_magic(magic)
                        && magic->mg_type != PERL_MAGIC_regex_global
                        && magic->mg_type != PERL_MAGIC_utf8) plain = FALSE;
            }
            if (!plain) croak("Wump: parallel byte downgrade requires a plain scalar");
            bool result = sv_utf8_downgrade(value, failok);
            Perl_wump_mutation_end(aTHX_ guard);
            SPAGAIN;
            ST(0) = boolSV(result);
            XSRETURN(1);
        }
        SV * const sv0 = ST(0);
C
		$entry =~ s/        SV \* const sv0 = ST\(0\);\n/$downgrade/ or die "missing downgrade inputs\n";
		substr($text, $start, $end - $start, $entry);
	}
	$start = index($text, "XS(XS_utf8_is_utf8)\n{");
	$end = index($text, "\n}\n", $start);
	$start >= 0 && $end >= 0 or die "missing UTF-8 flag query\n";
	$entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump UTF-8 flag query. */') >= 0) {
		my $query = <<'C';
        /* Wump UTF-8 flag query. */
        if (Perl_wump_parallel(aTHX)) {
            struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ sv);
            struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
            bool magical = SvGMAGICAL(sv);
            bool utf8 = SvUTF8(sv);
            Perl_wump_mutation_end(aTHX_ guard);
            Perl_wump_capture_end(aTHX_ capture);
            if (magical) croak("Wump: parallel UTF-8 flag query requires a nonmagical value");
            ST(0) = boolSV(utf8);
            XSRETURN(1);
        }
        SvGETMAGIC(sv);
C
		$entry =~ s/        SvGETMAGIC\(sv\);\n/$query/ or die "missing UTF-8 input fetch\n";
		substr($text, $start, $end - $start, $entry);
	}
	$start = index($text, "        XSANY.any_i32 = xsub->ix;");
	$end = index($text, "\n    } while", $start);
	$start >= 0 && $end >= 0 or die "missing native entry registration\n";
	my $registration = <<'C';
        XSANY.any_i32 = xsub->ix;
        if (xsub->xsub == XS_UNIVERSAL_can || xsub->xsub == XS_UNIVERSAL_isa || xsub->xsub == XS_NamedCapture_FETCH
            || xsub->xsub == XS_utf8_is_utf8 || xsub->xsub == XS_utf8_downgrade)
            Perl_wump_xs_allow(aTHX_ cv);
C
	chomp $registration;
	substr($text, $start, $end - $start, $registration);
	write_file($file, $text);
}
1;
