# Admit numeric getnameinfo only. Address/flag snapshots are private and
# resolver-backed calls remain outside the parallel preview.
sub apply_socket {
	my ($source) = @_;
	edit('cpan/Socket/Socket.xs', '#include <stddef.h>', "#include <stddef.h>\n#include <limits.h>");
	edit('cpan/Socket/Socket.xs', "static void xs_getnameinfo(pTHX_ CV *cv)\n", <<'C');
static SV *
wump_nameinfo_input(pTHX_ SV *input, bool integer)
{
    SV *copy = sv_newmortal();
    struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ input);
    struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
    bool plain = SvTYPE(input) <= SVt_PVMG && SvTYPE(input) != SVt_INVLIST
        && !SvROK(input) && !SvOBJECT(input) && !SvVALID(input);
    if (plain && SvTYPE(input) >= SVt_PVMG) {
        MAGIC *magic;
        for (magic = SvMAGIC(input); magic; magic = magic->mg_moremagic) {
            if (!Perl_wump_publish_magic(magic)) { plain = FALSE; break; }
        }
    }
    if (plain && integer) {
        plain = SvIOK(input);
        if (plain && SvIsUV(input)) {
            plain = SvUVX(input) <= INT_MAX;
            if (plain) sv_setiv(copy, (IV)SvUVX(input));
        } else if (plain) {
            IV value = SvIVX(input);
            plain = value >= INT_MIN && value <= INT_MAX;
            if (plain) sv_setiv(copy, value);
        }
    } else if (plain) {
        plain = SvPOKp(input) && !SvUTF8(input);
        if (plain) sv_setpvn(copy, SvPVX_const(input), SvCUR(input));
    }
    Perl_wump_mutation_end(aTHX_ guard);
    Perl_wump_capture_end(aTHX_ capture);
    if (!plain) croak("Wump: parallel socket metadata requires plain byte addresses and integer flags");
    return copy;
}

static void xs_getnameinfo(pTHX_ CV *cv)
C
	my $file = "$source/cpan/Socket/Socket.xs";
	my $text = read_file($file);
	my $start = index($text, "static void xs_getnameinfo(pTHX_ CV *cv)\n{");
	my $end = index($text, "\n}\n", $start);
	$start >= 0 && $end >= 0 or die "missing native getnameinfo\n";
	my $entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump numeric socket metadata. */') >= 0) {
		$entry =~ s/    addr = ST\(0\);/    \/\* Wump numeric socket metadata. \*\/\n    addr = Perl_wump_parallel(aTHX) ? wump_nameinfo_input(aTHX_ ST(0), FALSE) : ST(0);/
			or die "missing nameinfo address\n";
		for my $index (1, 2) {
			$entry =~ s/SvIV\(ST\(\Q$index\E\)\)/SvIV(Perl_wump_parallel(aTHX) ? wump_nameinfo_input(aTHX_ ST($index), TRUE) : ST($index))/
				or die "missing nameinfo flag $index\n";
		}
		my $policy = <<'C';
    want_serv = !(xflags & NIx_NOSERV);

    if (Perl_wump_parallel(aTHX)) {
        const int allowed = NI_NUMERICHOST | NI_NUMERICSERV | NI_DGRAM;
        if ((flags & ~allowed) || (xflags & ~(NIx_NOHOST | NIx_NOSERV))
            || (want_host && !(flags & NI_NUMERICHOST))
            || (want_serv && !(flags & NI_NUMERICSERV)))
            croak("Wump: parallel socket metadata requires numeric host and service");
        struct sockaddr_storage storage;
        Zero(&storage, 1, struct sockaddr_storage);
        STRLEN length = SvCUR(addr);
        bool valid = length >= sizeof(storage.ss_family) && length <= sizeof(storage);
        if (valid) {
            Copy(SvPVX_const(addr), &storage, length, char);
            valid = (storage.ss_family == AF_INET && length == sizeof(struct sockaddr_in));
#ifdef AF_INET6
            valid = valid || (storage.ss_family == AF_INET6 && length == sizeof(struct sockaddr_in6));
#endif
        }
        if (!valid) croak("Wump: parallel socket metadata requires an IPv4 or IPv6 sockaddr");
    }
C
		$entry =~ s/    want_serv = !\(xflags & NIx_NOSERV\);\n/$policy/
			or die "missing nameinfo output policy\n";
		substr($text, $start, $end - $start, $entry);
		write_file($file, $text);
	}
	edit('cpan/Socket/Socket.xs', "#ifdef HAS_GETNAMEINFO\n        newXS(\"Socket::getnameinfo\", xs_getnameinfo, __FILE__);\n#endif\n", <<'C');
#ifdef HAS_GETNAMEINFO
        CV *wump_nameinfo = newXS("Socket::getnameinfo", xs_getnameinfo, __FILE__);
        if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ wump_nameinfo);
#endif
C
}
1;
