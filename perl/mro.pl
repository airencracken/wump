# next::method resolves under the class-cache mutex, then tail-calls the
# returned method after the native frame has released its guard.
sub apply_mro {
	my ($source) = @_;
	edit('ext/mro/mro.xs', "MODULE = mro\t\tPACKAGE = mro\t\tPREFIX = mro_\n", <<'XS');
static SV *
wump_mro_input(pTHX_ SV *value, bool reference)
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
        croak("Wump: parallel next-method lookup requires a plain scalar or reference");
    }
    SV *copy = sv_mortalcopy(value);
    Perl_wump_capture_end(aTHX_ capture);
    return copy;
}

static SV *
wump_mro_reference(pTHX_ SV *value)
{
    SV *reference = newSV_type(SVt_IV);
    sv_setrv_inc(reference, value);
    return reference;
}

MODULE = mro		PACKAGE = mro		PREFIX = mro_
XS
	my $file = "$source/ext/mro/mro.xs";
	my $text = read_file($file);
	my $start = index($text, "\nmro__nextcan(...)\n");
	my $end = index($text, "\nBOOT:\n", $start);
	$start >= 0 && $end >= 0 or die "missing next-method native entry\n";
	my $entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump guarded next-method lookup. */') >= 0) {
		$entry =~ s/SV\* self = ST\(0\);/SV* self;/ or die "missing next-method receiver\n";
		$entry =~ s/const I32 throw_nomethod = SvIVX\(ST\(1\)\);/I32 throw_nomethod;/
			or die "missing next-method throw flag\n";
		my $prepare = <<'XS';
  PPCODE:
    /* Wump guarded next-method lookup. */
    if (items != 2) croak_xs_usage(cv, "self, throw_nomethod");
    struct wump_mutation *wump_guard = NULL;
    if (Perl_wump_parallel(aTHX)) {
        self = wump_mro_input(aTHX_ ST(0), TRUE);
        SV *flag = wump_mro_input(aTHX_ ST(1), FALSE);
        throw_nomethod = SvIV(flag);
        wump_guard = Perl_wump_metadata_begin(aTHX);
    } else {
        self = ST(0);
        throw_nomethod = SvIVX(ST(1));
    }
XS
		$entry =~ s/^  PPCODE:\n/$prepare/m or die "missing next-method body\n";
		my $returns = $entry =~ s/^(\h*)(XSRETURN(?:_EMPTY|\(1\));)/$1Perl_wump_mutation_end(aTHX_ wump_guard);\n$1$2/mg;
		$returns == 4 or die "expected four next-method return paths, found $returns\n";
		substr($text, $start, $end - $start, $entry);
		write_file($file, $text);
	}
	$text = read_file($file);
	$start = index($text, "\nmro__nextcan(...)\n");
	$end = index($text, "\nBOOT:\n", $start);
	$entry = substr($text, $start, $end - $start);
	$entry =~ s/\bnewRV_inc\(/wump_mro_reference(aTHX_ /g;
	substr($text, $start, $end - $start, $entry);
	write_file($file, $text);
	for my $value ('val', 'MUTABLE_SV(cand_cv)') {
		my $return = "mXPUSHs(wump_mro_reference(aTHX_ $value));";
		edit('ext/mro/mro.xs', $return,
			"if (Perl_wump_parallel(aTHX)) Perl_wump_publish(aTHX_ $value);\n            $return");
	}
	# A single-parent C3 result can reuse a mortal AV. Publish it before it
	# escapes into the shared cache so cleanup uses private temporary holders.
	edit('ext/mro/mro.xs', '    SvREADONLY_on(retval);', <<'XS');
    SvREADONLY_on(retval);
    if (Perl_wump_parallel(aTHX)) Perl_wump_publish(aTHX_ (SV *)retval);
XS
	edit('ext/mro/mro.xs', '    Perl_mro_register(aTHX_ &c3_alg);', <<'XS');
    Perl_mro_register(aTHX_ &c3_alg);
    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv("mro::_nextcan", 0));
XS
}
1;
