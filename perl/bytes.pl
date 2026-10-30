# These functional entries keep digest state and output buffers per call.
# Snapshot plain arguments before their native byte coercion touches caches.
sub bytes_boot {
	my ($source, $file, @names) = @_;
	my $text = read_file("$source/$file");
	return if index($text, '/* Wump parallel byte functions. */') >= 0;
	$text .= "\nBOOT:\n    /* Wump parallel byte functions. */\n    if (!PL_wump_task) {\n";
	$text .= "        Perl_wump_xs_allow(aTHX_ get_cv(\"$_\", 0));\n" for @names;
	$text .= "    }\n";
	write_file("$source/$file", $text);
}

sub bytes_prologue {
	my ($source, $file, $signature, $prepare) = @_;
	my $text = read_file("$source/$file");
	my $start = index($text, "\n$signature\n");
	$start >= 0 or die "missing byte entry $signature\n";
	pos($text) = $start;
	$text =~ /^[ \t]*(?:PP)?CODE:\n/mg or die "missing byte entry code $signature\n";
	my $at = $+[0];
	my $marker = "    /* Wump private byte arguments. */\n";
	return if substr($text, $at, length($marker)) eq $marker;
	substr($text, $at, 0, $marker . $prepare);
	write_file("$source/$file", $text);
}

sub apply_bytes {
	my ($source) = @_;
	my $args = <<'XS';
    if (Perl_wump_parallel(aTHX)) {
        for (I32 wump_arg = 0; wump_arg < items; wump_arg++)
            ST(wump_arg) = Perl_wump_xs_scalar(aTHX_ ST(wump_arg), "parallel byte conversion");
    }
XS
	bytes_prologue($source, 'cpan/Digest-MD5/MD5.xs', 'md5(...)', $args);
	bytes_boot($source, 'cpan/Digest-MD5/MD5.xs', 'Digest::MD5::md5');
	bytes_prologue($source, 'cpan/Digest-SHA/SHA.xs', 'sha1(...)', $args);
	bytes_boot($source, 'cpan/Digest-SHA/SHA.xs', 'Digest::SHA::sha1');
	my $base64 = 'cpan/MIME-Base64/Base64.xs';
	bytes_prologue($source, $base64, 'encode_base64(sv,...)', $args . "    sv = ST(0);\n");
	# decode_base64 originally coerces in PREINIT. Move that read after the
	# argument snapshot; the remaining declarations have no side effects.
	my $text = read_file("$source/$base64");
	my $start = index($text, "\ndecode_base64(sv)\n");
	my $end = index($text, "\n\tOUTPUT:\n", $start);
	$start >= 0 && $end >= 0 or die "missing base64 decoder declarations\n";
	my $entry = substr($text, $start, $end - $start);
	my $old = "\tunsigned char *str = (unsigned char*)SvPV(sv, len);\n\tunsigned char const* end = str + len;";
	my $new = "\tunsigned char *str;\n\tunsigned char const* end;";
	$entry =~ s/\Q$old\E/$new/ or die "missing base64 decoder input\n" if index($entry, $new) < 0;
	substr($text, $start, $end - $start, $entry);
	write_file("$source/$base64", $text);
	bytes_prologue($source, $base64, 'decode_base64(sv)', <<'XS');
    if (Perl_wump_parallel(aTHX))
        sv = Perl_wump_xs_scalar(aTHX_ sv, "parallel byte conversion");
    str = (unsigned char *)SvPV(sv, len);
    end = str + len;
XS
	bytes_boot($source, $base64, 'MIME::Base64::encode_base64', 'MIME::Base64::decode_base64');
}
1;
