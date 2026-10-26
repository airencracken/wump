# Native setting magic and the interpreter's fast caches share one binding.
sub apply_magic {
	my ($source) = @_;
	my $text = read_file("$source/mg.c");
	my $start = index($text, "    case '/':", index($text, 'Perl_magic_set('));
	my $end = index($text, "    case '[':", $start);
	$start >= 0 && $end > $start or die "mg.c: separator setter anchors missing\n";
	my $body = substr($text, $start, $end - $start);
	unless (index($body, 'Perl_wump_magic_target') >= 0) {
		$body =~ s/(    case '\/':\n        \{)/$1\n            SV **cache = Perl_wump_magic_target(aTHX_ sv, '\/');/;
		$body =~ s/\bPL_rs\b/(*cache)/g;
		$body =~ s/    case '\\\\':\n/    case '\\\\':\n        {\n        SV **cache = Perl_wump_magic_target(aTHX_ sv, '\\\\');\n/;
		$body =~ s/\bPL_ors_sv\b/(*cache)/g;
		$body =~ s/(        break;\n)\z/$1        }\n/;
	}
	$body =~ s/newSVsv\(sv\)/newSVsv_flags(sv, 0)/g;
	substr($text, $start, $end - $start, $body);
	write_file("$source/mg.c", $text);
	edit('mg.c', "    case ':':\n    case '/':\n        break;", <<'C');
    case ':':
        break;
    case '/':
        {
            SV **cache = Perl_wump_magic_owned(aTHX_ sv, '/');
            if (cache) sv_setsv_flags(sv, *cache, 0);
        }
        break;
C
	edit('mg.c', <<'OLD', <<'NEW');
    case '\\':
        if (PL_ors_sv)
            sv_copypv(sv, PL_ors_sv);
        else
            goto set_undef;
        break;
OLD
    case '\\':
        {
            SV *cache = *Perl_wump_magic_target(aTHX_ sv, '\\');
            if (cache) sv_copypv(sv, cache);
            else goto set_undef;
        }
        break;
NEW
	my $sys = read_file("$source/pp_sys.c");
	unless (index($sys, 'Perl_wump_magic_scope(aTHX_') >= 0) {
		my $input = $sys =~ s/^([ \t]*)SAVESPTR\(PL_rs\);/$1Perl_wump_magic_scope(aTHX_ '\/');\n$1SAVESPTR(PL_rs);/mg;
		my $output = $sys =~ s/^([ \t]*)SAVEGENERICSV\(PL_ors_sv\);/$1Perl_wump_magic_scope(aTHX_ '\\\\');\n$1SAVEGENERICSV(PL_ors_sv);/mg;
		$input == 2 && $output == 1 or die "pp_sys.c: unexpected separator scope count\n";
	}
	write_file("$source/pp_sys.c", $sys);
}
1;
