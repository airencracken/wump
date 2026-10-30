# Conservative baseline: all core SV counters are atomic. The owned-value
# fast path and safe concurrent allocation/reclamation remain separate work.
sub apply_refcount {
	my ($source) = @_;
	# Compiled pad names are shared by all act-local call frames. Their
	# ownership must remain atomic even though the frames themselves differ.
	edit('inline.h', '    PadnameREFCNT(pn)++;',
		'    __atomic_add_fetch(&PadnameREFCNT(pn), 1, __ATOMIC_RELAXED);');
	edit('inline.h', '    PadnamelistREFCNT(pnl)++;',
		'    __atomic_add_fetch(&PadnamelistREFCNT(pnl), 1, __ATOMIC_RELAXED);');
	edit('pad.c', '    if (!--PadnamelistREFCNT(pnl)) {',
		'    if (__atomic_fetch_sub(&PadnamelistREFCNT(pnl), 1, __ATOMIC_ACQ_REL) == 1) {');
	edit('pad.c', '    if (!--PadnameREFCNT(pn)) {',
		'    if (__atomic_fetch_sub(&PadnameREFCNT(pn), 1, __ATOMIC_ACQ_REL) == 1) {');
	edit('pad.c', '        PadnamelistREFCNT(padname = PL_comppad_name)++;',
		'        padname = PadnamelistREFCNT_inc(PL_comppad_name);');
	edit('pad.c', 'PL_padlist_generation++;',
		'__atomic_fetch_add(&PL_padlist_generation, 1, __ATOMIC_RELAXED);');
	my $counters = <<'C';
/* C++ XS retains the upstream head layout and lvalue API. Its standard
 * refcount helpers use compiler atomics; the C core uses C11 atomics on
 * its atomic-qualified field. Both access the same integer representation. */
#ifdef __cplusplus
#  define WUMP_REFCNT_TYPE U32
#  define WUMP_REFCNT_INC(sv) __atomic_add_fetch(&(sv)->sv_refcnt, 1, __ATOMIC_RELAXED)
#  define WUMP_REFCNT_LOAD(sv) __atomic_load_n(&(sv)->sv_refcnt, __ATOMIC_ACQUIRE)
#  define WUMP_REFCNT_CAS(sv, rc) \
    __atomic_compare_exchange_n(&(sv)->sv_refcnt, &(rc), (rc)-1, 0, \
        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)
#else
#  include <stdatomic.h>
#  define WUMP_REFCNT_TYPE _Atomic(U32)
#  define WUMP_REFCNT_INC(sv) atomic_fetch_add_explicit(&(sv)->sv_refcnt, 1, memory_order_relaxed)
#  define WUMP_REFCNT_LOAD(sv) atomic_load_explicit(&(sv)->sv_refcnt, memory_order_acquire)
#  define WUMP_REFCNT_CAS(sv, rc) \
    atomic_compare_exchange_strong_explicit(&(sv)->sv_refcnt, &(rc), (rc)-1, \
        memory_order_acq_rel, memory_order_acquire)
#endif
C
	my $current = read_file("$source/sv.h");
	my $start = index($current, "/* start with 2 sv-head building blocks */\n");
	$start >= 0 or die "missing scalar head marker\n";
	$start += length("/* start with 2 sv-head building blocks */\n");
	my $end = index($current, '#define _SV_HEAD(ptrtype)', $start);
	$end >= 0 or die "missing scalar head declaration\n";
	my $existing = substr($current, $start, $end - $start);
	$existing !~ /\S/ || index($existing, 'WUMP_REFCNT_TYPE') >= 0
		or die "unexpected content before scalar head declaration\n";
	substr($current, $start, $end - $start, "$counters\n");
	write_file("$source/sv.h", $current);
	edit('sv.h', "    U32\t\tsv_refcnt;", "    WUMP_REFCNT_TYPE sv_refcnt;");
	my $head = read_file("$source/sv.h");
	$head =~ s/\(\+\+\(SvREFCNT\(sv\)\),MUTABLE_SV\(sv\)\)/(WUMP_REFCNT_INC(sv),MUTABLE_SV(sv))/g;
	$head =~ s/\(void\)\(\+\+SvREFCNT\(MUTABLE_SV\(sv\)\)\)/(void)WUMP_REFCNT_INC(MUTABLE_SV(sv))/g;
	write_file("$source/sv.h", $head);
	my $inline = read_file("$source/sv_inline.h");
	$inline =~ s/SvREFCNT\(sv\)\+\+;/WUMP_REFCNT_INC(sv);/g;
	$inline =~ s/U32 rc = SvREFCNT\(sv\);/U32 rc = WUMP_REFCNT_LOAD(sv);/g;
	my $dec = <<'C';
Perl_SvREFCNT_dec(pTHX_ SV *sv)
{
    if (LIKELY(sv != NULL)) {
        U32 rc = WUMP_REFCNT_LOAD(sv);
        while (rc > 1) {
            if (WUMP_REFCNT_CAS(sv, rc)) return;
        }
        /* A terminal drop still uses Perl's existing destruction path.
         * No other thread may acquire a reference without owning one. */
        Perl_sv_free2(aTHX_ sv, rc);
    }
}
C
	$inline =~ s/Perl_SvREFCNT_dec\(pTHX_ SV \*sv\)\n\{.*?\n\}\n/$dec/s
		or die "missing refcount decrement\n";
	$dec = <<'C';
Perl_SvREFCNT_dec_NN(pTHX_ SV *sv)
{
    PERL_ARGS_ASSERT_SVREFCNT_DEC_NN;
    Perl_SvREFCNT_dec(aTHX_ sv);
}
C
	$inline =~ s/Perl_SvREFCNT_dec_NN\(pTHX_ SV \*sv\)\n\{.*?\n\}\n/$dec/s
		or die "missing non-null refcount decrement\n";
	write_file("$source/sv_inline.h", $inline);
	# RC-stack pairs must use the same atomic decrement, even when their
	# initial counts suggest that neither value will need freeing.
	my $stack = read_file("$source/inline.h");
	$stack =~ s/SvREFCNT\((sv[12])\) = rc[12] - 1;/SvREFCNT_dec_NN($1);/g;
	write_file("$source/inline.h", $stack);
}
1;
