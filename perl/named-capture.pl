# The built-in capture hash keeps iteration state in act-local HVs. Its
# scalar/FETCH/EXISTS entry uses immutable API flags and the act's own match.
sub apply_named_capture {
	my ($source) = @_;
	edit('universal.c', "XS(XS_NamedCapture_FETCH)\n", <<'C');
EXTCONST regexp_engine PL_core_reg_engine;

STATIC SV *
S_wump_named_input(pTHX_ SV *input, bool object)
{
    SV *copy = sv_newmortal();
    struct wump_borrow *head = Perl_wump_capture_begin(aTHX_ input);
    struct wump_borrow *body = NULL;
    struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
    SV *value = input;
    bool valid = !SvGMAGICAL(input) && !SvWEAKREF(input);
    bool reference = object && SvROK(input);
    if (valid && reference) {
        value = SvRV(input);
        body = Perl_wump_capture_begin(aTHX_ value);
    }
    if (reference || !object) {
        valid = valid && SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
            && !SvROK(value) && (object || !SvOBJECT(value)) && !SvVALID(value);
        if (valid && object && SvOBJECT(value)) {
            const char *name = HvNAME_get(SvSTASH(value));
            valid = name && strEQ(name, "Tie::Hash::NamedCapture") && !Gv_AMG(SvSTASH(value));
        }
        if (valid && SvTYPE(value) >= SVt_PVMG) {
            MAGIC *magic;
            for (magic = SvMAGIC(value); magic; magic = magic->mg_moremagic) {
                if (!Perl_wump_publish_magic(magic)) { valid = FALSE; break; }
            }
        }
        if (valid && object) {
            valid = SvIOK(value);
            if (valid) {
                UV flags = SvIsUV(value) ? SvUVX(value) : (UV)SvIVX(value);
                valid = flags == RXapif_ONE || flags == RXapif_ALL;
                if (valid) sv_setrv_noinc(copy, newSVuv(flags));
            }
        } else if (valid) {
            valid = SvPOK(value);
            if (valid) {
                sv_setpvn(copy, SvPVX_const(value), SvCUR(value));
                if (SvUTF8(value)) SvUTF8_on(copy);
            }
        }
    }
    Perl_wump_mutation_end(aTHX_ guard);
    Perl_wump_capture_end(aTHX_ body);
    Perl_wump_capture_end(aTHX_ head);
    if (!valid) croak("Wump: parallel named captures require plain names and native API flags");
    return copy;
}

XS(XS_NamedCapture_FETCH)
C
	my $file = "$source/universal.c";
	my $text = read_file($file);
	my $start = index($text, "XS(XS_NamedCapture_FETCH)\n{");
	my $end = index($text, "\n}\n", $start);
	$start >= 0 && $end >= 0 or die "missing named capture entry\n";
	my $entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump named capture admission.') >= 0) {
		my $prepare = <<'C';
        /* Wump named capture admission. All aliases share this XSUB. */
        if (Perl_wump_parallel(aTHX)) {
            if (action != RXapif_FETCH && action != RXapif_EXISTS && action != RXapif_SCALAR)
                croak_no_modify();
            if (rx && RX_ENGINE(rx) != &PL_core_reg_engine)
                croak("Wump: parallel named captures require the native regex engine");
            ST(0) = S_wump_named_input(aTHX_ ST(0), TRUE);
        }

        if (!rx || !SvROK(ST(0))) {
C
		$entry =~ s/        if \(!rx \|\| !SvROK\(ST\(0\)\)\) \{\n/$prepare/
			or die "missing named capture object check\n";
		$entry =~ s/        flags = \(U32\)SvUV\(SvRV\(MUTABLE_SV\(ST\(0\)\)\)\);/        if (Perl_wump_parallel(aTHX) \&\& expect >= 2)\n            ST(1) = S_wump_named_input(aTHX_ ST(1), FALSE);\n        flags = (U32)SvUV(SvRV(MUTABLE_SV(ST(0))));/
			or die "missing named capture flags\n";
		substr($text, $start, $end - $start, $entry);
		write_file($file, $text);
	}
}
1;
