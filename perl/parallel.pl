# Keep class-cache inspection and initialization in one short native region.
# Actual Perl method bodies execute only after that region has ended.
sub apply_parallel {
	my ($source) = @_;
	memory_guard($source, 'universal.c', 'isa_lookup', 'bool', 'stash',
		'Perl_wump_parallel(aTHX)', undef, 1, 'S_');
	for my $spec (
		['gv.c', 'gv_fetchmethod_pvn_flags', 'GV *'],
		['gv.c', 'gv_fetchmeth_pvn', 'GV *'],
		['gv.c', 'gv_autoload_pvn', 'GV *'],
		['gv.c', 'gv_stashsvpvn_cached', 'HV *'],
		['gv.c', 'gv_handler', 'CV *'],
		['mro_core.c', 'mro_get_linear_isa', 'AV *'],
	) {
		my ($file, $name, $type) = @$spec;
		memory_guard($source, $file, $name, $type, 'stash',
			'Perl_wump_parallel(aTHX)', undef, 1);
	}
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	for my $name (qw(method method_named method_super method_redir method_redir_super)) {
		my $marker = "/* Wump method-cache wrapper: $name */";
		next if index($text, $marker) >= 0;
		$text =~ /^PP\(pp_\Q$name\E\)\n\{/mg or die "missing method opcode $name\n";
		my $start = $-[0];
		my $end = index($text, "\n}\n", pos($text));
		$end >= 0 or die "missing end of method opcode $name\n";
		$end += 3;
		my $body = substr($text, $start, $end - $start);
		$body =~ s/^PP\(pp_\Q$name\E\)/PP(wump_method_impl_$name)/ or die "rename $name failed\n";
		$body .= "\n$marker\nPP(pp_$name)\n{\n"
			. "    if (!Perl_wump_parallel(aTHX)) return Perl_wump_method_impl_$name(aTHX);\n"
			. "    struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);\n"
			. "    OP *next = Perl_wump_method_impl_$name(aTHX);\n"
			. "    Perl_wump_mutation_end(aTHX_ guard);\n    return next;\n}\n";
		substr($text, $start, $end - $start, $body);
	}
	write_file($file, $text);
	# Repeated references to a published closure must not rewrite its flags
	# while an earlier act is entering the same shared CV.
	$file = "$source/pp.c";
	$text = read_file($file);
	my $start = index($text, "S_refto(pTHX_ SV *sv)\n{");
	$start >= 0 or die "missing reference constructor\n";
	my $end = index($text, "\n}\n", $start);
	$end >= 0 or die "missing reference constructor end\n";
	my $body = substr($text, $start, $end - $start);
	my $cleared = $body =~ s/^        SvTEMP_off\(sv\);/        if (!PL_wump_task || !Perl_wump_is_shared(aTHX_ sv)) SvTEMP_off(sv);/mg;
	$cleared == 2 || (!$cleared && $body =~ /Perl_wump_is_shared/)
		or die "unexpected reference constructor TEMP flags\n";
	substr($text, $start, $end - $start, $body);
	write_file($file, $text);
	# A cached MRO value outlives the creating act's temporary scope. Keep
	# its temporary reference in a private RV so scope cleanup cannot rewrite
	# flags on the cache head after another act starts using it.
	edit('mro_core.c', '#include "perl.h"', <<'C');
#include "perl.h"

STATIC void
S_wump_mro_keep(pTHX_ SV *value)
{
    if (!Perl_wump_parallel(aTHX)) return;
    for (SSize_t i = PL_tmps_ix; i >= 0; i--) {
        if (PL_tmps_stack[i] != value) continue;
        SV *holder = newRV_noinc(value);
        SvTEMP_on(holder);
        PL_tmps_stack[i] = holder;
    }
}
C
	edit('mro_core.c', '    meta->isa = stored;',
		"    S_wump_mro_keep(aTHX_ (SV *)stored);\n    meta->isa = stored;");
	edit('mro_core.c', '    SvREADONLY_on(retval);',
		"    SvREADONLY_on(retval);\n    S_wump_mro_keep(aTHX_ (SV *)retval);");
	# Object finalization has its own DESTROY cache and bypasses ordinary
	# method opcodes. End the guard before calling the Perl destructor.
	edit('sv.c', '            CV* destructor = NULL;',
		"            CV* destructor = NULL;\n            struct wump_mutation *destroy_guard = Perl_wump_parallel(aTHX) ? Perl_wump_metadata_begin(aTHX) : NULL;");
	edit('sv.c', '            assert(!destructor || SvTYPE(destructor) == SVt_PVCV);',
		"            Perl_wump_mutation_end(aTHX_ destroy_guard);\n            assert(!destructor || SvTYPE(destructor) == SVt_PVCV);");
}
1;
