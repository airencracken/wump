use strict;
use warnings;
use Digest::SHA 'sha256_hex';
use File::Find 'find';
use File::Copy 'copy';
use File::Basename 'dirname';
use File::Path 'make_path';
use File::Temp 'tempdir';

@ARGV == 1 or die "usage: $0 SOURCE\n";
my $source = $ARGV[0];
sub snapshot {
	my ($source) = @_;
	my %files;
	find({no_chdir => 1, wanted => sub {
		return unless -f $_ && /\.(?:c|h|xs|pm|y|act)\z/;
		open my $fh, '<', $_ or die "$_: $!\n";
		binmode $fh;
		local $/;
		$files{$_} = sha256_hex(<$fh>);
	}}, $source);
	return \%files;
}
my $before = snapshot($source);
system 'perl', 'perl/apply.pl', $source;
$? == 0 or die "patcher failed: $?\n";
my $after = snapshot($source);
my @changed = grep { !exists $before->{$_} || $before->{$_} ne $after->{$_} } keys %$after;
push @changed, grep { !exists $after->{$_} } keys %$before;
die "reapplying patches changed source:\n", join("\n", sort @changed), "\n" if @changed;
print "ok - reapplying patches preserves every source file\n";

my $legacy = tempdir('wump-key-upgrade-XXXXXX', TMPDIR => 1, CLEANUP => 1);
for my $file (keys %$after) {
	(my $relative = $file) =~ s/^\Q$source\E\/// or die "unexpected path: $file\n";
	make_path(dirname("$legacy/$relative"));
	copy($file, "$legacy/$relative") or die "copy $file: $!\n";
}
for my $file ('perl.c', 'sv.c') {
	open my $input, '<', "$legacy/$file" or die "$file: $!\n";
	local $/;
	my $text = <$input>;
	close $input or die "$file: $!\n";
	# Restore the earlier key-lock lifecycle without touching the other
	# generated patches. Upgrading must preserve exactly one mutex init.
	$text =~ s/^    (?:aTHX->Iwump_memory = NULL;|Perl_wump_memory_(?:init|destroy)\(aTHX\);)\n//mg;
	open my $output, '>', "$legacy/$file" or die "$file: $!\n";
	print {$output} $text or die "$file: $!\n";
	close $output or die "$file: $!\n";
}
{
	my $file = "$legacy/pp_hot.c";
	open my $input, '<', $file or die "$file: $!\n";
	local $/;
	my $text = <$input>;
	close $input or die "$file: $!\n";
	# Restore the previous existing-cell load blocks before exercising the
	# older read-only/reference upgrades. The new pass must rebuild them all.
	$text =~ s{    if \(PL_wump_task && CvISXSUB\(cv\)\) \{\n        Perl_wump_xs_check\(aTHX_ cv\);\n        Perl_wump_publish\(aTHX_ \(SV \*\)cv\);\n    \}}{    if (PL_wump_task && CvISXSUB(cv)) Perl_wump_publish(aTHX_ (SV *)cv);}
		or die "missing parallel XS gate\n";
	for my $name (qw(method method_named method_super method_redir method_redir_super)) {
		$text =~ s/^PP\(wump_method_impl_\Q$name\E\)/PP(pp_$name)/m
			or die "missing guarded method implementation $name\n";
		$text =~ s{\n/\* Wump method-cache wrapper: \Q$name\E \*/\nPP\(pp_\Q$name\E\)\n\{\n.*?^\}\n}{}ms
			or die "missing method wrapper $name\n";
	}
	for my $spec (
		['aelemfast', 'sv', 'av, key', 'av', ''],
		['aelem', 'retsv', 'av, elem', 'av', ' && !localizing && !(PL_op->op_private & OPpDEREF)'],
		['helem', 'retsv', 'hv, keysv', 'hv', ' && !localizing && !(PL_op->op_private & OPpDEREF)'],
	) {
		my ($name, $result, $args, $kind, $condition) = @$spec;
		my $start = index($text, "PP(pp_$name)\n{");
		my $call = index($text, "$result = lval ? Perl_wump_lvalue_$kind", $start);
		$call >= 0 or die "missing materialized $name load\n";
		my $at = rindex($text, '    if (PL_wump_task', $call);
		my $end = index($text, "\n    }\n", $call) + 6;
		my $old = "    if (PL_wump_task$condition) {\n        bool handled;\n"
			. "        $result = Perl_wump_load_$kind(aTHX_ $args, &handled);\n"
			. "        if (handled && (!lval || $result != &PL_sv_undef)) goto ret;\n    }";
		substr($text, $at, $end - $at, $old);
	}
	for my $kind ('av', 'hv') {
		my $cast = uc($kind);
		my $key = $kind eq 'av' ? 'elem' : 'keysv';
		$text =~ s/Perl_wump_lvalue_\Q$kind\E\(aTHX_ \(\Q$cast\E \*\)sv, \Q$key\E, FALSE, &handled\)/Perl_wump_load_$kind(aTHX_ ($cast *)sv, $key, \&handled)/
			or die "missing materialized intermediate $kind\n";
		my $call = index($text, "SV *loaded = lval ? Perl_wump_lvalue_$kind");
		$call >= 0 or die "missing materialized final $kind\n";
		my $at = rindex($text, '                    if (PL_wump_task', $call);
		my $end = index($text, "\n                    }\n", $call) + 22;
		my $old = "                    if (PL_wump_task && !localizing) {\n                        bool handled;\n"
			. "                        SV *loaded = Perl_wump_load_$kind(aTHX_ ($cast *)sv, $key, &handled);\n"
			. "                        if (handled && (!lval || loaded != &PL_sv_undef)) { sv = loaded; goto finish; }\n                    }";
		substr($text, $at, $end - $at, $old);
	}
	$text =~ s{^/\* Wump lvalue materialization \*/\n}{} or die "missing materialization marker\n";
	$text =~ s{        if \(PL_wump_task\) Perl_wump_vivify_value\(aTHX_ sv, to_what\);\n        else \{\n}{}
		or die "missing vivification materialization\n";
	$text =~ s{        SvROK_on\(sv\);\n        \}\n        SvSETMAGIC\(sv\);}{        SvROK_on(sv);\n        SvSETMAGIC(sv);}
		or die "missing vivification materialization end\n";
	# Remove the aggregate reference upgrade as well as the later lvalue
	# guards so an old generated tree exercises both upgrade stages.
	my $references = $text =~ s{^[ ]*/\* Wump reference capture:[^\n]+\*/\n.*?^[ ]*/\* End Wump reference capture \*/\n}{}gms;
	$references == 5 or die "expected five reference captures, found $references\n";
	$text =~ s{^/\* Wump aggregate reference loads \*/\n}{} or die "missing reference upgrade marker\n";
	$text =~ s/^  wump_aggregate_loaded:\n//m or die "missing reference upgrade label\n";
	# Recreate the previous read-only load guards in a complete generated tree.
	# Reapplying must upgrade all five sites and preserve every other patch.
	my $count = $text =~ s{
		^([ ]*)if\ \(PL_wump_task(?:\ &&\ !localizing(?:\ &&\ !\(PL_op->op_private\ &\ OPpDEREF\))?)?\)\ \{\n
		\1\ \ \ \ bool\ handled;\n
		(\1\ \ \ \ (?:SV\ \*)?\w+\ =\ Perl_wump_load_[ah]v[^\n]+\n)
		\1\ \ \ \ if\ \(handled\ &&\ \(!lval\ \|\|\ \w+\ !=\ &PL_sv_undef\)\)([^\n]+)\n
		\1\}
	}{"$1" . "if (PL_wump_task && !lval) {\n$1    bool handled;\n$2$1    if (handled)$3\n$1}"}gmex;
	$count == 5 or die "expected five existing-lvalue guards, found $count\n";
	$text =~ s{\n/\* Wump existing lvalue loads \*/\n}{} or die "missing lvalue upgrade marker\n";
	open my $output, '>', $file or die "$file: $!\n";
	print {$output} $text or die "$file: $!\n";
	close $output or die "$file: $!\n";
}
{
	my $file = "$legacy/pp.c";
	open my $input, '<', $file or die "$file: $!\n";
	my $text = do { local $/; <$input> };
	close $input or die "$file: $!\n";
	$text =~ s{^/\* Wump scalar reference loads \*/\n}{}
		or die "missing scalar reference upgrade marker\n";
	$text =~ s{^    /\* Wump reference capture: rv2sv \*/\n.*?^    /\* End Wump reference capture \*/\n}{}ms
		or die "missing scalar reference capture\n";
	$text =~ s/^  wump_scalar_loaded:\n//m or die "missing scalar reference label\n";
	open my $output, '>', $file or die "$file: $!\n";
	print {$output} $text or die "$file: $!\n";
	close $output or die "$file: $!\n";
}
for my $spec (
	['mg.c', [qw(defelem_target vivify_defelem magic_getdefelem magic_setdefelem)]],
	['pp_hot.c', ['vivify_ref']],
	['sv.c', [qw(sv_add_backref sv_del_backref)]],
	['gv.c', [qw(gv_fetchmethod_pvn_flags gv_fetchmeth_pvn gv_autoload_pvn gv_stashsvpvn_cached gv_handler)]],
	['mro_core.c', ['mro_get_linear_isa']],
	['universal.c', ['isa_lookup'], 'S_'],
) {
	my ($file, $names, $prefix) = @$spec;
	$prefix //= 'Perl_';
	open my $input, '<', "$legacy/$file" or die "$file: $!\n";
	my $text = do { local $/; <$input> };
	close $input or die "$file: $!\n";
	for my $name (@$names) {
		$text =~ s/^#define \Q$prefix$name\E wump_memory_impl_\Q$name\E\n//m
			or die "missing $name wrapper definition\n";
		$text =~ s{^#undef \Q$prefix$name\E\n\n/\* Wump mutation wrapper: \Q$name\E \*/\n[^\n]+\n\Q$prefix$name\E\([^\n]*\n\{\n.*?^\}\n}{}ms
			or die "missing $name wrapper body\n";
	}
	if ($file eq 'mg.c') {
		$text =~ s{^/\* Wump deferred ownership commit \*/\n}{} or die "missing deferred ownership marker\n";
		$text =~ s/NOOP; \/\* no value; common commit releases the old array \*\//LvTARG(sv) = NULL;\t\/\* array can't be extended *\//
			or die "missing nonextendible ownership fix\n";
		$text =~ s{    SV \*old_target = LvTARG\(sv\), \*old_key = mg->mg_obj;\n    LvTARG\(sv\) = SvREFCNT_inc\(value\);\n    LvTARGLEN\(sv\) = 0;\n    mg->mg_obj = NULL;\n    mg->mg_flags &= ~MGf_REFCOUNTED;\n    SvREFCNT_dec\(old_target\);\n    SvREFCNT_dec\(old_key\);}{    SvREFCNT_inc_simple_void(value);\n    SvREFCNT_dec(LvTARG(sv));\n    LvTARG(sv) = value;\n    LvTARGLEN(sv) = 0;\n    SvREFCNT_dec(mg->mg_obj);\n    mg->mg_obj = NULL;\n    mg->mg_flags &= ~MGf_REFCOUNTED;}
			or die "missing deferred creation commit\n";
		$text =~ s{            SV \*old_target = LvTARG\(sv\), \*old_key = mg->mg_obj;\n            LvTARG\(sv\) = SvREFCNT_inc_simple_NN\(targ\);\n            LvTARGLEN\(sv\) = 0;\n            mg->mg_obj = NULL;\n            mg->mg_flags &= ~MGf_REFCOUNTED;\n            SvREFCNT_dec\(old_target\);\n            SvREFCNT_dec\(old_key\);}{            SvREFCNT_dec(LvTARG(sv));\n            LvTARG(sv) = SvREFCNT_inc_simple_NN(targ);\n            LvTARGLEN(sv) = 0;\n            SvREFCNT_dec(mg->mg_obj);\n            mg->mg_obj = NULL;\n            mg->mg_flags &= ~MGf_REFCOUNTED;}
			or die "missing deferred lookup commit\n";
	}
	open my $output, '>', "$legacy/$file" or die "$file: $!\n";
	print {$output} $text or die "$file: $!\n";
	close $output or die "$file: $!\n";
}
system 'perl', 'perl/apply.pl', $legacy;
$? == 0 or die "legacy lifecycle upgrade failed: $?\n";
my $upgraded = snapshot($legacy);
for my $file (keys %$after) {
	(my $relative = $file) =~ s/^\Q$source\E\///;
	$upgraded->{"$legacy/$relative"} eq $after->{$file}
		or die "legacy lifecycle upgrade changed $relative\n";
}
print "ok - upgrading earlier lifecycle, reference loads, deferred ownership and parallel metadata/XS guards preserves the complete generated tree\n";
