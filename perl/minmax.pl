sub apply_minmax {
	my ($source) = @_;
	my $file = 'cpan/Scalar-List-Utils/ListUtil.xs';
	my $text = read_file("$source/$file");
	my $start = index($text, "\nmin(...)\n");
	my $end = index($text, "\n\nvoid\nsum(...)\n", $start);
	$start >= 0 && $end >= 0 or die "missing min/max entry\n";
	my $entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump private min/max inputs. */') >= 0) {
		$entry =~ s/    int magic;\n/    int magic;\n    AV *wump_originals = NULL;\n/ or die "missing min/max locals\n";
		my $prepare = <<'XS';
    /* Wump private min/max inputs. */
    if (Perl_wump_parallel(aTHX)) {
        wump_originals = (AV *)sv_2mortal((SV *)newAV());
        for (I32 arg = 0; arg < items; arg++) {
            SV *original = ST(arg);
            SV *copy = Perl_wump_xs_scalar(aTHX_ original, "parallel min/max");
            av_push(wump_originals, newRV_inc(original));
            ST(arg) = copy;
        }
    }
    retsv = ST(0);
XS
		$entry =~ s/    retsv = ST\(0\);\n/$prepare/ or die "missing min/max initial value\n";
		my $result = <<'XS';
    if (wump_originals) {
        for (I32 arg = 0; arg < items; arg++) {
            if (ST(arg) == retsv) {
                retsv = SvRV(AvARRAY(wump_originals)[arg]);
                break;
            }
        }
    }
    ST(0) = retsv;
XS
		$entry =~ s/    ST\(0\) = retsv;\n/$result/ or die "missing min/max result\n";
	}
	substr($text, $start, $end - $start, $entry);
	write_file("$source/$file", $text);
	edit($file, "BOOT:\n{\n", <<'XS');
BOOT:
{
    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv("List::Util::min", 0));
XS
	my $min_allow = "    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv(\"List::Util::min\", 0));\n";
	edit($file, $min_allow, $min_allow
		. "    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv(\"Scalar::Util::looks_like_number\", 0));\n");
	$text = read_file("$source/$file");
	$start = index($text, "\nlooks_like_number(sv)\n");
	$end = index($text, "\nOUTPUT:\n", $start);
	$start >= 0 && $end >= 0 or die "missing numeric classification entry\n";
	$entry = substr($text, $start, $end - $start);
	my $copy = "    if (Perl_wump_parallel(aTHX))\n"
		. "        sv = Perl_wump_xs_scalar(aTHX_ sv, \"parallel number query\");\n";
	$entry =~ s/    SvGETMAGIC\(sv\);/$copy    SvGETMAGIC(sv);/
		unless index($entry, 'parallel number query') >= 0;
	substr($text, $start, $end - $start, $entry);
	write_file("$source/$file", $text);
}
1;
