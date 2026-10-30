# Keep class-cache inspection and initialization in one short native region.
# Actual Perl method bodies execute only after that region has ended.
sub apply_parallel {
	my ($source) = @_;
	# Reference generation and tail-call dispatch inspect heads which a
	# sibling can be publishing for the first time. Read flags under the
	# publication mutex without holding it across magic or lvalue callbacks.
	for my $file (qw(pp.c pp_ctl.c)) {
		edit($file, '#include "perl.h"', <<'C');
#include "perl.h"

STATIC U32
S_wump_reference_flags(pTHX_ const SV *value)
{
    if (!Perl_wump_parallel(aTHX)) return SvFLAGS(value);
    Perl_wump_memory_lock(aTHX);
    U32 flags = SvFLAGS(value);
    Perl_wump_memory_unlock(aTHX);
    return flags;
}
C
		my $path = "$source/$file";
		my $text = read_file($path);
		my $signature = $file eq 'pp.c' ? 'S_refto(pTHX_ SV *sv)' : 'PP(pp_goto)';
		my $start = index($text, "$signature\n{");
		my $end = index($text, "\n}\n", $start);
		$start >= 0 && $end >= 0 or die "missing reference entry in $file\n";
		my $body = substr($text, $start, $end - $start);
		for my $spec ([SvTYPE => 'SVTYPEMASK'], [SvPADTMP => 'SVs_PADTMP'],
			[SvSMAGICAL => 'SVs_SMG'], [SvTEMP => 'SVs_TEMP'], [SvROK => 'SVf_ROK']) {
			my ($macro, $mask) = @$spec;
			$body =~ s/\b\Q$macro\E\(sv\)/(S_wump_reference_flags(aTHX_ sv) \& $mask)/g;
		}
		$body =~ s/SvTYPE\(SvRV\(sv\)\)/(S_wump_reference_flags(aTHX_ SvRV(sv)) \& SVTYPEMASK)/g;
		$body =~ s/AvREAL\(\(const AV \*\)sv\)/(S_wump_reference_flags(aTHX_ sv) \& SVpav_REAL)/g;
		$body =~ s/AvREIFY\(\(const AV \*\)sv\)/(S_wump_reference_flags(aTHX_ sv) \& SVpav_REIFY)/g;
		substr($text, $start, $end - $start, $body);
		write_file($path, $text);
	}
	# Immortal values can appear on native temporary stacks. Sorting or
	# freeing those references must not rewrite interpreter-wide TEMP flags.
	{
		my $path = "$source/pp_hot.c";
		my $text = read_file($path);
		my $start = index($text, "Perl_leave_adjust_stacks(pTHX_ SV **from_sp, SV **to_sp, U8 gimme, int pass)\n{");
		my $end = index($text, "\n}\n", $start);
		$start >= 0 && $end >= 0 or die "missing return temporary cleanup\n";
		my $body = substr($text, $start, $end - $start);
		$body =~ s/(?<!if \(!SvIMMORTAL\(sv\)\) )SvTEMP_(on|off)\(sv\);/if (!SvIMMORTAL(sv)) SvTEMP_$1(sv);/g;
		substr($text, $start, $end - $start, $body);
		write_file($path, $text);
	}
	edit('scope.c', '            SvTEMP_off(sv);',
		'            if (!SvIMMORTAL(sv)) SvTEMP_off(sv);');
	# List repetition keeps aliases. Constants can be shared before graph
	# publication; avoid rewriting their already-clear TEMP bit. Published
	# heads retain their flags just as in reference construction below.
	edit('pp.c', '                   SvTEMP_off((*SP));', <<'C');
                   if (!PL_wump_task || ((S_wump_reference_flags(aTHX_ *SP) & SVs_TEMP)
                       && !Perl_wump_is_shared(aTHX_ *SP))) SvTEMP_off((*SP));
C
	# goto &sub unrolls cx_pushsub and bypasses ordinary entersub. Prepare
	# the target before unwinding the donor frame: preparation can throw.
	edit('pp_ctl.c', "            /* First do some returnish stuff. */\n", <<'C');
            if (PL_wump_task) {
                if (CvISXSUB(cv)) {
                    Perl_wump_xs_check(aTHX_ cv);
                    Perl_wump_publish(aTHX_ (SV *)cv);
                } else {
                    Perl_wump_cv_prepare(aTHX_ cv);
                }
            }

            /* First do some returnish stuff. */
C
	# A shared value can acquire a new mortal ownership too. Keep that
	# ownership in a private holder instead of changing the shared TEMP bit.
	edit('sv.c', "Perl_sv_2mortal(pTHX_ SV *const sv)\n{\n    if (!sv)\n        return sv;", <<'C');
Perl_sv_2mortal(pTHX_ SV *const sv)
{
    if (!sv)
        return sv;
    if (PL_wump_task && Perl_wump_memory_shared(aTHX_ sv) == 1) {
        EXTEND_MORTAL(1);
        SV *holder = newSV_type(SVt_IV);
        sv_setrv_noinc(holder, sv);
        SvTEMP_on(holder);
        PL_tmps_stack[++PL_tmps_ix] = holder;
        return sv;
    }
C
	my $scalar_file = "$source/sv.c";
	my $scalar_text = read_file($scalar_file);
	my $copy_start = index($scalar_text, "Perl_sv_mortalcopy_flags(pTHX_ SV *const oldstr, U32 flags)\n{");
	my $copy_end = index($scalar_text, "\n}\n", $copy_start);
	$copy_start >= 0 && $copy_end >= 0 or die "missing mortal scalar copy\n";
	my $copy = substr($scalar_text, $copy_start, $copy_end - $copy_start);
	unless (index($copy, 'return sv_2mortal(sv);') >= 0) {
		$copy =~ s/    PUSH_EXTEND_MORTAL__SV_C\(sv\);\n    SvTEMP_on\(sv\);\n    return sv;/    return sv_2mortal(sv);/
			or die "missing mortal scalar copy ownership\n";
		substr($scalar_text, $copy_start, $copy_end - $copy_start, $copy);
		write_file($scalar_file, $scalar_text);
	}
	# Overload-cache initialization rewrites the stash head's flags. These
	# macros are also read outside method opcodes, including callee resolution.
	edit('sv.h', "#define HvAMAGIC(hv)\t\t(SvFLAGS(hv) & SVf_AMAGIC)",
		'#define HvAMAGIC(hv) Perl_wump_stash_amagic((HV *)(hv), 0)');
	edit('sv.h', "#define HvAMAGIC_on(hv)\t\t(SvFLAGS(hv) |= SVf_AMAGIC)",
		'#define HvAMAGIC_on(hv) Perl_wump_stash_amagic((HV *)(hv), 1)');
	edit('sv.h', "#define HvAMAGIC_off(hv)\t(SvFLAGS(hv) &=~ SVf_AMAGIC)",
		'#define HvAMAGIC_off(hv) Perl_wump_stash_amagic((HV *)(hv), -1)');
	my $sv = read_file("$source/sv.h");
	unless (index($sv, '#define Gv_AMG(stash) Perl_wump_stash_amg(aTHX_ stash)') >= 0) {
		$sv =~ s/^#define Gv_AMG\(stash\) \\\n.*?: \(HvAMAGIC_off\(stash\), 0\)\)/#define Gv_AMG(stash) Perl_wump_stash_amg(aTHX_ stash)/ms
			or die "missing overload cache predicate\n";
		write_file("$source/sv.h", $sv);
	}
	memory_guard($source, 'universal.c', 'isa_lookup', 'bool', 'stash',
		'Perl_wump_parallel(aTHX)', undef, 1, 'S_');
	for my $spec (
		['gv.c', 'gv_fetchmethod_pvn_flags', 'GV *'],
		['gv.c', 'gv_fetchmeth_pvn', 'GV *'],
		['gv.c', 'gv_autoload_pvn', 'GV *'],
		['gv.c', 'gv_stashsvpvn_cached', 'HV *'],
		['gv.c', 'gp_ref', 'GP *'],
		['gv.c', 'Gv_AMupdate', 'int'],
		['gv.c', 'gv_handler', 'CV *'],
		['mro_core.c', 'mro_get_linear_isa', 'AV *'],
		['mro_core.c', 'mro_isa_changed_in', 'void'],
		['mro_core.c', 'mro_method_changed_in', 'void'],
		['mro_core.c', 'mro_package_moved', 'void'],
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
	# First entry can publish a CV (and its constant callee RVs) while a
	# sibling resolves that same call. Snapshot head flags under the metadata
	# mutex; never keep it held across magic or overloaded dereferencing.
	$text = read_file($file);
	unless (index($text, 'S_wump_callee_flags(pTHX_') >= 0) {
		my $helper = <<'C';
STATIC U32
S_wump_callee_flags(pTHX_ const SV *value)
{
    if (!Perl_wump_parallel(aTHX)) return SvFLAGS(value);
    Perl_wump_memory_lock(aTHX);
    U32 flags = SvFLAGS(value);
    Perl_wump_memory_unlock(aTHX);
    return flags;
}

C
		$text =~ s/^PP\(pp_entersub\)/$helper . 'PP(pp_entersub)'/me
			or die "missing subroutine entry\n";
	}
	my $call_start = index($text, "PP(pp_entersub)\n{");
	my $call_end = index($text, "\n}\n", $call_start);
	$call_start >= 0 && $call_end >= 0 or die "missing subroutine entry body\n";
	my $call = substr($text, $call_start, $call_end - $call_start);
	$call =~ s/SvFLAGS\(sv\)/S_wump_callee_flags(aTHX_ sv)/g;
	$call =~ s/SvOBJECT\(cv\)/(S_wump_callee_flags(aTHX_ (SV *)cv) \& SVs_OBJECT)/g;
	$call =~ s/SvTYPE\(cv\)/(S_wump_callee_flags(aTHX_ (SV *)cv) \& SVTYPEMASK)/g;
	$call =~ s/switch \(SvTYPE\(sv\)\)/switch (S_wump_callee_flags(aTHX_ sv) \& SVTYPEMASK)/g;
	substr($text, $call_start, $call_end - $call_start, $call);
	write_file($file, $text);
	# Foreach aliases an element; clearing its TEMP flag is a write to a
	# published head even when the flag was already clear.
	$file = "$source/pp_hot.c";
	$text = read_file($file);
	my $iter_start = index($text, "PP(pp_iter)\n{");
	$iter_start >= 0 or die "missing foreach iterator\n";
	my $iter_end = index($text, "\n}\n", $iter_start);
	$iter_end >= 0 or die "missing foreach iterator end\n";
	my $iterator = substr($text, $iter_start, $iter_end - $iter_start);
	$iterator =~ s/SvTEMP_off\(sv\);/if (!PL_wump_task || !Perl_wump_is_shared(aTHX_ sv)) SvTEMP_off(sv);/
		unless $iterator =~ /Perl_wump_is_shared/;
	substr($text, $iter_start, $iter_end - $iter_start, $iterator);
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
	# Compiled constants can be shared before publication too. Do not write
	# their already-clear flag merely to construct a reference to them.
	my $cleared = $body =~ s/^        (?:if \(!PL_wump_task \|\| !Perl_wump_is_shared\(aTHX_ sv\)\) )?SvTEMP_off\(sv\);/        if (SvTEMP(sv) \&\& (!PL_wump_task || !Perl_wump_is_shared(aTHX_ sv))) SvTEMP_off(sv);/mg;
	$cleared == 2 || (!$cleared && $body =~ /if \((?:SvTEMP\(sv\)|\(S_wump_reference_flags\(aTHX_ sv\) & SVs_TEMP\)) &&/)
		or die "unexpected reference constructor TEMP flags\n";
	$body =~ s/SvTEMP\(sv\)/(S_wump_reference_flags(aTHX_ sv) \& SVs_TEMP)/g;
	substr($text, $start, $end - $start, $body);
	write_file($file, $text);
	# Overload-table construction changes both stash magic and the cached
	# dereference bit. Its readers must synchronize with first construction.
	edit('gv.c', <<'OLD', <<'NEW');
    assert(HvHasAUX(stash));
    if (HvAUX(stash)->xhv_aux_flags & HvAUXf_NO_DEREF)
        return ref;
OLD
    bool wump_parallel_deref = Perl_wump_parallel(aTHX);
    if (wump_parallel_deref) Perl_wump_memory_lock(aTHX);
    assert(HvHasAUX(stash));
    bool wump_no_deref = cBOOL(HvAUX(stash)->xhv_aux_flags & HvAUXf_NO_DEREF);
    if (wump_parallel_deref) Perl_wump_memory_unlock(aTHX);
    if (wump_no_deref)
        return ref;
NEW
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
	# Localization anchors share GP reference counts. Serialize their short
	# retain/release paths, but release before freeing values or callbacks.
	edit('gv.c', '    bool in_global_destruction = PL_phase == PERL_PHASE_DESTRUCT;',
		"    bool in_global_destruction = PL_phase == PERL_PHASE_DESTRUCT;\n    struct wump_mutation *wump_gp_guard = NULL;");
	edit('gv.c', '    if (gp->gp_refcnt == 0) {',
		"    wump_gp_guard = Perl_wump_parallel(aTHX) ? Perl_wump_metadata_begin(aTHX) : NULL;\n    if (gp->gp_refcnt == 0) {\n        Perl_wump_mutation_end(aTHX_ wump_gp_guard);");
	edit('gv.c', '       borrowed:',
		"       borrowed:\n        if (!wump_gp_guard && Perl_wump_parallel(aTHX))\n            wump_gp_guard = Perl_wump_metadata_begin(aTHX);");
	edit('gv.c', "        gp->gp_refcnt--;\n        GvGP_set(gv, NULL);\n        return;\n    }",
		"        gp->gp_refcnt--;\n        GvGP_set(gv, NULL);\n        Perl_wump_mutation_end(aTHX_ wump_gp_guard);\n        return;\n    }\n    Perl_wump_mutation_end(aTHX_ wump_gp_guard);\n    wump_gp_guard = NULL;");
	edit('gv.c', '    if (gp->gp_refcnt > 1) goto borrowed;',
		"    wump_gp_guard = Perl_wump_parallel(aTHX) ? Perl_wump_metadata_begin(aTHX) : NULL;\n    if (gp->gp_refcnt > 1) goto borrowed;\n    Perl_wump_mutation_end(aTHX_ wump_gp_guard);");
}
1;
