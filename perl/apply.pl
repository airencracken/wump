#!/usr/bin/perl
use strict;
use warnings;
use FindBin;

@ARGV == 1 or die "usage: $0 SOURCE_DIRECTORY\n";
my $source = $ARGV[0];
sub read_file {
	my ($path) = @_;
	open my $fh, '<', $path or die "$path: $!\n";
	local $/;
	return <$fh>;
}
sub write_file {
	my ($path, $text) = @_;
	return if -f $path && read_file($path) eq $text;
	if (-f $path && !-w $path) {
		chmod((stat($path))[2] | 0200, $path) or die "chmod $path: $!\n";
	}
	open my $fh, '>', $path or die "$path: $!\n";
	print {$fh} $text or die "$path: $!\n";
	close $fh or die "$path: $!\n";
}
sub edit {
	my ($file, $old, $new) = @_;
	my $text = read_file("$source/$file");
	return if index($text, $new) >= 0;
	my $count = $text =~ s/\Q$old\E/$new/g;
	$count == 1 or die "$file: expected one patch location, found $count\n";
	write_file("$source/$file", $text);
}
my @vars = grep { length && !/^#/ } split /\n/, read_file("$FindBin::Bin/taskvars");
my $intrp = read_file("$source/intrpvar.h");
my %types;
while ($intrp =~ /PERLVAR(?:I|IC)?\(\s*I,\s*(\w+),\s*([^,\)]+)(?:,[^\)]*)?\)/g) {
	my ($name, $type) = ($1, $2);
	$type =~ s/\s+$//;
	$types{$name} = $type;
}
my $header = "/* Generated from Perl's intrpvar.h by perl/apply.pl. */\n";
$header .= "START_EXTERN_C\n";
$header .= "struct wump_read_frame;\n";
$header .= "struct wump_memory;\nstruct wump_mutation;\nstruct wump_retired;\n";
$header .= "struct wump_shared;\nstruct wump_borrow;\n";
$header .= "struct wump_cv_slot;\nstruct wump_regex_slot;\nstruct wump_local;\nstruct wump_element;\nstruct wump_element_iter;\nstruct wump_perl_task {\n";
for my $name (@vars) {
	exists $types{$name} or die "Missing upstream interpreter field: $name\n";
	$header .= "\t$types{$name} I$name;\n";
}
$header .= <<'C';
	PerlInterpreter *interp;
	CV *entry;
	struct wump_cv_slot *cvs;
	struct wump_regex_slot *regexes;
	struct wump_local *locals;
	struct wump_element *elements;
	struct wump_element_iter *element_iters;
	struct wump_read_frame *read_frame;
	UV next_binding;
	UV id;
	int initialized, finished, main;
	unsigned critical;
};
I32 *Perl_wump_cv_depth(pTHX_ const CV *cv);
PADLIST **Perl_wump_cv_padlist(CV *cv);
void Perl_wump_cv_prepare(pTHX_ CV *cv);
void Perl_wump_boot(pTHX);
int Perl_wump_main(pTHX);
int Perl_wump_runops(pTHX);
int Perl_wump_active_runops(pTHX_ struct wump_perl_task *task);
void Perl_wump_checkpoint(pTHX);
void Perl_wump_xs_allow(pTHX_ CV *cv);
void Perl_wump_xs_check(pTHX_ CV *cv);
bool Perl_wump_parallel(pTHX);
bool Perl_wump_numeric_enter(pTHX_ SV *target);
void Perl_wump_numeric_leave(pTHX);
SV *Perl_wump_xs_scalar(pTHX_ SV *value, const char *operation);
U32 Perl_wump_stash_amagic(HV *stash, int operation);
bool Perl_wump_stash_amg(pTHX_ HV *stash);
void Perl_wump_panic(pTHX_ SV *error);
SV **Perl_wump_gv_sv(GV *gv);
AV **Perl_wump_gv_av(GV *gv);
void Perl_wump_pm_stamp(pTHX_ PMOP *pm);
SV **Perl_wump_pm_slot(pTHX_ PMOP *pm);
REGEXP *Perl_wump_pm_get(pTHX_ PMOP *pm);
bool Perl_wump_pm_native(pTHX_ PMOP *pm, REGEXP *rx);
HV *Perl_wump_regex_names(pTHX_ HV *original);
HV **Perl_wump_gv_hv(GV *gv);
SV *Perl_wump_localize(pTHX_ GV *gv, char kind);
void Perl_wump_local_elements_check(pTHX);
void Perl_wump_save_defsv(pTHX);
bool Perl_wump_element_magic(const MAGIC *mg);
SV **Perl_wump_local_av(pTHX_ AV *av, SSize_t index);
HE *Perl_wump_local_hv(pTHX_ HV *hv, SV *key);
SV **Perl_wump_av_slot(pTHX_ AV *av, SSize_t *index, bool lval, bool *handled);
SSize_t Perl_wump_av_fill(AV *av);
void Perl_wump_element_structure(pTHX_ SV *aggregate);
bool Perl_wump_hv_slot(pTHX_ HV *hv, const char *key, STRLEN len, int flags,
	int action, SV *value, U32 hash, void **result);
HV *Perl_wump_hv_iteration(pTHX_ HV *hv, bool reset);
bool Perl_wump_hv_readable(pTHX_ HV *hv);
void Perl_wump_hv_publish_cursor(pTHX_ HV *hv);
bool Perl_wump_hv_iter_reset(pTHX_ HV *hv, I32 *count);
HE *Perl_wump_hv_iter_next(pTHX_ HV *hv, I32 flags, bool *handled);
STRLEN Perl_wump_hv_used(HV *hv);
void Perl_wump_elements_clear(pTHX_ struct wump_perl_task *task);
void Perl_wump_elements_snapshot(pTHX_ struct wump_perl_task *task);
HV *Perl_wump_hv_clone(pTHX_ HV *hv);
void Perl_wump_snapshot_check(pTHX_ SV *value, char kind);
AV *Perl_wump_snapshot_av(pTHX_ AV *source);
HV *Perl_wump_snapshot_hv(pTHX_ HV *source);
char Perl_wump_magic_kind(pTHX_ SV *value);
SV *Perl_wump_magic_new(pTHX_ char kind, SV *initial);
SV *Perl_wump_magic_copy(pTHX_ SV *value);
SV **Perl_wump_magic_owned(pTHX_ SV *value, char kind);
SV **Perl_wump_magic_target(pTHX_ SV *value, char kind);
SV **Perl_wump_magic_cache(pTHX_ char kind);
void Perl_wump_magic_scope(pTHX_ char kind);
SV **Perl_wump_hook_cache(pTHX_ char kind);
char Perl_wump_hook_kind(pTHX_ HV *hv, SV *key);
U8 *Perl_wump_warning_owned(pTHX_ SV *value);
U8 *Perl_wump_warning_target(pTHX_ SV *value);
U8 *Perl_wump_warning_cache(pTHX);
void Perl_wump_lock(pTHX_ SV *value);
void Perl_wump_save_capture(pTHX_ GV *gv);
void Perl_wump_hook_store(pTHX_ SV *value, char kind);
bool Perl_wump_publish_magic(const MAGIC *mg);
void Perl_wump_memory_init(pTHX);
void Perl_wump_memory_destroy(pTHX);
void Perl_wump_memory_lock(pTHX);
void Perl_wump_memory_unlock(pTHX);
void Perl_wump_memory_mark(pTHX_ SV *value, unsigned state);
int Perl_wump_memory_shared(pTHX_ const SV *value);
void Perl_wump_memory_check(pTHX_ const SV *value);
void Perl_wump_memory_forget(pTHX_ SV *value);
void Perl_wump_memory_collect(pTHX);
void Perl_wump_memory_stats(pTHX_ size_t *pins, size_t *retired, size_t *nodes);
void Perl_wump_memory_clone(pTHX);
void Perl_wump_memory_clone_check(pTHX);
struct wump_shared *Perl_wump_read_begin(pTHX_ const SV *value);
bool Perl_wump_read_try_begin(pTHX_ const SV *value, struct wump_shared **claim);
void Perl_wump_read_end(pTHX_ struct wump_shared *claim);
struct wump_borrow *Perl_wump_capture_begin(pTHX_ const SV *value);
void Perl_wump_capture_end(pTHX_ struct wump_borrow *capture);
IV Perl_wump_cache_iv(pTHX_ SV *value, I32 flags);
UV Perl_wump_cache_uv(pTHX_ SV *value, I32 flags);
NV Perl_wump_cache_nv(pTHX_ SV *value, I32 flags);
bool Perl_wump_cache_truth(pTHX_ SV *value, I32 flags, bool fallback);
char *Perl_wump_pv_encoded(pTHX_ SV *value, STRLEN *length, U32 flags, int encoding, bool or_null);
struct wump_retired *Perl_wump_retire_prepare(pTHX_ SV *value);
void Perl_wump_retire_commit(pTHX_ struct wump_retired *retired);
struct wump_mutation *Perl_wump_mutation_begin(pTHX_ SV *value);
struct wump_mutation *Perl_wump_metadata_begin(pTHX);
struct wump_mutation *Perl_wump_mutation_try_begin(pTHX_ SV *value, bool *busy);
void Perl_wump_mutation_end(pTHX_ struct wump_mutation *guard);
const char *Perl_wump_mutation_pointer(pTHX_ struct wump_mutation *guard, const char *pointer);
void Perl_wump_mutation_keep(pTHX_ SV *value, SV *retained);
void Perl_wump_storage_changed(pTHX_ SV *value);
bool Perl_wump_overlay_active(pTHX_ const SV *value);
bool Perl_wump_publish_active(pTHX);
char *Perl_wump_pv(pTHX_ SV *value, STRLEN *length, U32 flags);
SV **Perl_wump_borrow_av(pTHX_ AV *value, SSize_t index);
SV *Perl_wump_load_rv(pTHX_ SV *value, svtype type, bool *handled);
SV *Perl_wump_load_av(pTHX_ AV *value, SSize_t index, bool *handled);
SV *Perl_wump_load_hv(pTHX_ HV *value, SV *key, bool *handled);
SV *Perl_wump_lvalue_av(pTHX_ AV *value, SSize_t index, bool defer, bool *handled);
SV *Perl_wump_lvalue_hv(pTHX_ HV *value, SV *key, bool defer, bool *handled);
void Perl_wump_vivify_value(pTHX_ SV *value, U32 kind);
HE *Perl_wump_borrow_hv(pTHX_ HV *value, const char *key, STRLEN length, U32 hash);
void Perl_wump_sv_detach(pTHX_ SV *value);
bool Perl_wump_cow_retain(pTHX_ SV *value);
void Perl_wump_av_detach(pTHX_ AV *value);
void Perl_wump_hv_detach(pTHX_ HV *value);
bool Perl_wump_is_shared(pTHX_ const SV *value);
bool Perl_wump_readable(pTHX_ const SV *value);
SV *Perl_wump_scalar_snapshot(pTHX_ const SV *value);
const SV *Perl_wump_read_origin(pTHX_ const SV *value);
IV Perl_wump_read_iv(pTHX_ SV *value, I32 flags);
UV Perl_wump_read_uv(pTHX_ SV *value, I32 flags);
NV Perl_wump_read_nv(pTHX_ SV *value, I32 flags);
bool Perl_wump_read_bool(pTHX_ SV *value, I32 flags);
char *Perl_wump_read_pv(pTHX_ SV *value, STRLEN *length, U32 flags, int encoding);
char *Perl_wump_read_snapshot_pv(pTHX_ SV *value, SV *copy, STRLEN *length, U32 flags, int encoding);
void Perl_wump_read_copy(pTHX_ SV *target, SV *value, I32 flags);
struct wump_operands;
struct wump_operands *Perl_wump_operands_begin(pTHX_ SV *target);
void Perl_wump_operands_end(pTHX_ struct wump_operands *guard);
void Perl_wump_publish(pTHX_ SV *value);
void Perl_wump_publish_store(pTHX_ SV *owner, SV *value);
void Perl_wump_publish_reference(pTHX_ SV *owner, SV *value);
void Perl_wump_publish_snapshot(pTHX_ SV *value);
void Perl_wump_publish_refresh(pTHX_ SV *value);
struct wump_perl_task *Perl_wump_task_current(pTHX);
void Perl_wump_task_activate(pTHX_ struct wump_perl_task *task);
/* Executor caches are independent of tasks: migrating acts allocate/free
 * through the destination executor. Merge only after all users stop. */
struct wump_perl_allocator {
	PerlInterpreter *interp;
	SV *Isv_root, *Isv_arenaroot;
	IV Isv_count;
	bool Inomemok;
#ifdef PERL_HASH_RANDOMIZE_KEYS
	UV Ihash_rand_bits;
#endif
	void *Ibody_arenas;
	void *Ibody_roots[PERL_ARENA_ROOTS_SIZE];
};
struct wump_perl_allocator *Perl_wump_allocator_current(pTHX);
void Perl_wump_allocator_init(pTHX_ struct wump_perl_allocator *pool);
void Perl_wump_allocator_activate(pTHX_ struct wump_perl_allocator *pool);
void Perl_wump_allocator_merge(pTHX_ struct wump_perl_allocator *pool);
SV **Perl_wump_allocator_sv_root(pTHX);
SV **Perl_wump_allocator_sv_arenaroot(pTHX);
IV *Perl_wump_allocator_sv_count(pTHX);
bool *Perl_wump_allocator_nomemok(pTHX);
#ifdef PERL_HASH_RANDOMIZE_KEYS
UV *Perl_wump_allocator_hash_rand_bits(pTHX);
#endif
HEK *Perl_wump_hek_retain(const HEK *hek);
void **Perl_wump_allocator_body_arenas(pTHX);
void *(*Perl_wump_allocator_body_roots(pTHX))[PERL_ARENA_ROOTS_SIZE];
void Perl_wump_regex_roots(pTHX_ REGEXP *rx,
	void (*visit)(pTHX_ SV *, void *), void *arg);
#include "wump_plain_ops.h"
END_EXTERN_C
C
write_file("$source/wump_task_types.h", $header);
if (index(read_file("$source/perl.h"), '#include "wump_task_types.h"') < 0) {
	edit('perl.h', "struct interpreter {\n#  include \"intrpvar.h\"\n};",
		"#include \"wump_task_types.h\"\nstruct interpreter {\n#  include \"intrpvar.h\"\n    struct wump_perl_task *Iwump_task;\n};");
}
edit('perl.h', "    struct wump_perl_task *Iwump_task;",
	"    struct wump_perl_task *Iwump_task;\n    bool Iwump_publishing;");
edit('perl.h', "    bool Iwump_publishing;",
	"    bool Iwump_publishing;\n    bool Iwump_enabled;");
edit('perl.h', "    bool Iwump_enabled;",
	"    bool Iwump_enabled;\n    perl_mutex Iwump_keys_mutex;\n    bool Iwump_keys_ready;");
edit('perl.h', "    bool Iwump_keys_ready;",
	"    bool Iwump_keys_ready;\n    struct wump_read_frame *Iwump_read_frame;");
edit('perl.h', "    struct wump_read_frame *Iwump_read_frame;",
	"    struct wump_read_frame *Iwump_read_frame;\n    struct wump_memory *Iwump_memory;");
edit('perl.h', "    struct wump_memory *Iwump_memory;",
	"    struct wump_memory *Iwump_memory;\n    U32 Iwump_context_seen;");
# perl_clone switches locale before zeroing the newly malloc'd interpreter.
# DEBUGGING then poisons it again before accessing redirected state lvalues.
edit('sv.c', "    my_perl->Iphase = PERL_PHASE_CONSTRUCT;\n    PERL_SET_THX(my_perl);",
	"    my_perl->Iphase = PERL_PHASE_CONSTRUCT;\n    my_perl->Iwump_context_seen = 0;\n    PERL_SET_THX(my_perl);");
edit('sv.c', '    PoisonNew(my_perl, 1, PerlInterpreter);',
	"    PoisonNew(my_perl, 1, PerlInterpreter);\n    my_perl->Iwump_context_seen = 0;");
# Keep the former task slot reserved for private-layout compatibility;
# execution selects its task through TLS, never through that shared slot.
my $vars = "\n/* Wump execution state: root execution retains the upstream fields. */\n";
$vars .= <<'C';
#if defined(MULTIPLICITY)
/* Sticky, initially zero from perl_alloc. This is not a task pointer or a
 * publication barrier. Activation on the calling thread sets it before TLS;
 * it is never cleared when another executor might still have a context. */
PERL_STATIC_INLINE bool
S_wump_context_seen(pTHX)
{
    return __atomic_load_n(&aTHX->Iwump_context_seen, __ATOMIC_RELAXED) != 0;
}
PERL_STATIC_INLINE void
S_wump_context_mark(pTHX)
{
    if (!S_wump_context_seen(aTHX))
        __atomic_store_n(&aTHX->Iwump_context_seen, 1, __ATOMIC_RELAXED);
}
PERL_STATIC_INLINE struct wump_perl_task *
S_wump_task_context(pTHX)
{
    if (!S_wump_context_seen(aTHX)) return NULL;
#if defined(__x86_64__) && defined(__ELF__)
    struct wump_perl_task *task;
    UV offset;
    /* Only the module's TLS offset is invariant. Read through the current
     * FS base every time; a cached native TLS address cannot survive an
     * act migrating inside an allocating or callback-capable C frame. */
    __asm__("movq Perl_wump_task_tls@gottpoff(%%rip), %0" : "=r" (offset));
    __asm__ volatile("movq %%fs:(%1), %0" : "=r" (task) : "r" (offset) : "memory");
    return task && task->interp == aTHX ? task : NULL;
#else
    return Perl_wump_task_current(aTHX);
#endif
}
PERL_STATIC_INLINE struct wump_perl_allocator *
S_wump_pool_context(pTHX)
{
    if (!S_wump_context_seen(aTHX)) return NULL;
#if defined(__x86_64__) && defined(__ELF__)
    struct wump_perl_allocator *pool;
    UV offset;
    __asm__("movq Perl_wump_allocator_tls@gottpoff(%%rip), %0" : "=r" (offset));
    __asm__ volatile("movq %%fs:(%1), %0" : "=r" (pool) : "r" (offset) : "memory");
    return pool && pool->interp == aTHX ? pool : NULL;
#else
    return Perl_wump_allocator_current(aTHX);
#endif
}
#define PL_wump_task S_wump_task_context(aTHX)
C
for my $name (@vars) {
	# Select once per field access. The selector reloads through the current
	# executor's FS base even when inlined, including after act migration.
	$vars .= "PERL_STATIC_INLINE $types{$name} *\nS_wump_state_$name(pTHX)\n{\n"
		. "    struct wump_perl_task *task = PL_wump_task;\n"
		. "    return task && !task->main ? &task->I$name : &aTHX->I$name;\n}\n"
		. "#undef PL_$name\n#define PL_$name (*S_wump_state_$name(aTHX))\n";
}
for my $name (qw(sv_root sv_arenaroot sv_count body_arenas body_roots nomemok)) {
	my $type = $name eq 'sv_count' ? 'IV' : $name eq 'nomemok' ? 'bool'
		: $name eq 'body_arenas' ? 'void *' : $name eq 'body_roots' ? undef : 'SV *';
	if (defined $type) {
		$vars .= "PERL_STATIC_INLINE $type *\nS_wump_pool_$name(pTHX)\n{\n"
			. "    struct wump_perl_allocator *pool = S_wump_pool_context(aTHX);\n"
			. "    return pool ? &pool->I$name : &aTHX->I$name;\n}\n"
			. "#undef PL_$name\n#define PL_$name (*S_wump_pool_$name(aTHX))\n";
	} else {
		$vars .= <<'C';
PERL_STATIC_INLINE void *(*S_wump_pool_body_roots(pTHX))[PERL_ARENA_ROOTS_SIZE]
{
    struct wump_perl_allocator *pool = S_wump_pool_context(aTHX);
    return pool ? &pool->Ibody_roots : &aTHX->Ibody_roots;
}
#undef PL_body_roots
#define PL_body_roots (*S_wump_pool_body_roots(aTHX))
C
	}
}
$vars .= <<'C';
#ifdef PERL_HASH_RANDOMIZE_KEYS
PERL_STATIC_INLINE UV *S_wump_pool_hash_rand_bits(pTHX)
{
    struct wump_perl_allocator *pool = S_wump_pool_context(aTHX);
    return pool ? &pool->Ihash_rand_bits : &aTHX->Ihash_rand_bits;
}
#undef PL_hash_rand_bits
#define PL_hash_rand_bits (*S_wump_pool_hash_rand_bits(aTHX))
#endif
C
$vars .= "#endif\n";
my $magic_cache_macros = <<'C';
#undef PL_rs
#define PL_rs (*(PL_wump_task ? Perl_wump_magic_cache(aTHX_ '/') : &aTHX->Irs))
#undef PL_ors_sv
#define PL_ors_sv (*(PL_wump_task ? Perl_wump_magic_cache(aTHX_ '\\') : &aTHX->Iors_sv))
#undef PL_diehook
#define PL_diehook (*(PL_wump_task ? Perl_wump_hook_cache(aTHX_ 'D') : &aTHX->Idiehook))
#undef PL_warnhook
#define PL_warnhook (*(PL_wump_task ? Perl_wump_hook_cache(aTHX_ 'W') : &aTHX->Iwarnhook))
#undef PL_dowarn
#define PL_dowarn (*(PL_wump_task ? Perl_wump_warning_cache(aTHX) : &aTHX->Idowarn))
C
$vars =~ s/#endif\n\z/$magic_cache_macros#endif\n/;
my $root_macros = "#ifdef WUMP_ROOT_CONTEXT\n#undef PL_wump_task\n#define PL_wump_task NULL\n";
my %root_fields;
for my $name (@vars, qw(sv_root sv_arenaroot sv_count body_arenas body_roots nomemok rs ors_sv diehook warnhook dowarn)) {
	next if $root_fields{$name}++;
	$root_macros .= "#undef PL_$name\n#define PL_$name (aTHX->I$name)\n";
}
$root_macros .= "#ifdef PERL_HASH_RANDOMIZE_KEYS\n#undef PL_hash_rand_bits\n#define PL_hash_rand_bits (aTHX->Ihash_rand_bits)\n#endif\n#endif\n";
$vars =~ s/#endif\n\z/$root_macros#endif\n/;
write_file("$source/wump_task_embed.h", $vars);
my $embed = read_file("$source/embedvar.h");
$embed =~ s/\n\/\* Wump execution state:.*\z//s;
write_file("$source/embedvar.h", $embed);
edit('perl.h', '#  include "embedvar.h"', "#  include \"embedvar.h\"\n#  include \"wump_task_embed.h\"");
edit('inline.h', 'return &((XPVCV*)SvANY(sv))->xcv_depth;',
	"dTHX;\n    return Perl_wump_cv_depth(aTHX_ sv);");
edit('cv.h', '&(((XPVCV*)MUTABLE_PTR(SvANY(sv)))->xcv_padlist_u.xcv_padlist)))',
	'Perl_wump_cv_padlist((CV *)(sv))))');
my $inline = read_file("$source/inline.h");
$inline =~ s/    cx->blk_sub.cv = cv;\n    Perl_wump_cv_prepare\(aTHX_ cv\);\n    cx->blk_sub.olddepth/    cx->blk_sub.cv = cv;\n    cx->blk_sub.olddepth/;
write_file("$source/inline.h", $inline);
edit('inline.h', '    PERL_ARGS_ASSERT_CX_PUSHSUB;', <<'C');
    PERL_ARGS_ASSERT_CX_PUSHSUB;

    /* Publication can throw. Until preparation succeeds this context owns
     * only cx_pushblock's initialized fields, not a CV, pad or argument AV. */
    const U8 wump_sub_type = cx->cx_type;
    cx->cx_type = CXt_NULL;
    Perl_wump_cv_prepare(aTHX_ cv);
    cx->cx_type = wump_sub_type;
C
edit('gv.h', "#define GvSV(gv)\t(GvGP(gv)->gp_sv)",
	"#define GvSV(gv)\t(*Perl_wump_gv_sv((GV *)(gv)))");
edit('gv.h', "#define GvAV(gv)\t(GvGP(gv)->gp_av)",
	"#define GvAV(gv)\t(*Perl_wump_gv_av((GV *)(gv)))");
edit('gv.h', "#define GvHV(gv)\t((GvGP(gv))->gp_hv)",
	"#define GvHV(gv)\t(*Perl_wump_gv_hv((GV *)(gv)))");
my $gv = read_file("$source/gv.h");
$gv =~ s/\QGvGP(gv)->gp_sv ?\E/GvSV(gv) ?/g;
$gv =~ s/\Q&(GvGP(gv)->gp_sv) :\E/\&GvSV(gv) :/g;
$gv =~ s/\QGvGP(gv)->gp_av ?\E/GvAV(gv) ?/g;
$gv =~ s/\QGvGP(gv)->gp_av :\E/GvAV(gv) :/g;
$gv =~ s/\QGvGP(gv)->gp_hv ?\E/GvHV(gv) ?/g;
$gv =~ s/\QGvGP(gv)->gp_hv :\E/GvHV(gv) :/g;
$gv =~ s/\QGvGP(gv_HVadd(gv))->gp_hv\E/GvHV(gv_HVadd(gv))/g;
$gv =~ s/\Q&(GvGP(gv_SVadd(gv))->gp_sv)\E/\&GvSV(gv_SVadd(gv))/g;
$gv =~ s/\QGvGP(gv_AVadd(gv))->gp_av\E/GvAV(gv_AVadd(gv))/g;
write_file("$source/gv.h", $gv);
edit('gv.h', "#define GvSV(gv)\t(*Perl_wump_gv_sv((GV *)(gv)))", <<'C');
#ifdef WUMP_ROOT_CONTEXT
#define GvSV(gv) (GvGP(gv)->gp_sv)
#else
#define GvSV(gv)	(*Perl_wump_gv_sv((GV *)(gv)))
#endif
C
edit('gv.h', "#define GvAV(gv)\t(*Perl_wump_gv_av((GV *)(gv)))", <<'C');
#ifdef WUMP_ROOT_CONTEXT
#define GvAV(gv) (GvGP(gv)->gp_av)
#else
#define GvAV(gv)	(*Perl_wump_gv_av((GV *)(gv)))
#endif
C
edit('gv.h', "#define GvHV(gv)\t(*Perl_wump_gv_hv((GV *)(gv)))", <<'C');
#ifdef WUMP_ROOT_CONTEXT
#define GvHV(gv) (GvGP(gv)->gp_hv)
#else
#define GvHV(gv)	(*Perl_wump_gv_hv((GV *)(gv)))
#endif
C
# Normalize earlier generated prologues before applying the combined gate.
# Keeping the gate and task redirection together makes reapplication stable.
my $scope = read_file("$source/scope.c");
my $gate = "\n    if (!PL_wump_task && PL_op && PL_op->op_wump_pocket)\n        croak(\"Wump: pocket requires a running task\");";
for my $spec ([scalar => 'SV', 's'], [ary => 'AV', 'a'], [hash => 'HV', 'h'], [gp => '', '']) {
	my ($name, $type, $kind) = @$spec;
	my $args = $kind ? 'GV *gv' : 'GV *gv, I32 empty';
	my $start = "Perl_save_$name(pTHX_ $args)\n{";
	my $redirect = $kind
		? "\n    if (PL_wump_task) return ($type *)Perl_wump_localize(aTHX_ gv, '$kind');"
		: "\n    if (PL_wump_task) croak(\"Wump: typeglob localization in a task is not supported yet\");";
	my $count = $scope =~ s/\Q$start\E(?:\Q$gate\E|\Q$redirect\E)*/$start$gate$redirect/g;
	$count == 1 or die "scope.c: expected one $name prologue, found $count\n";
}
write_file("$source/scope.c", $scope);
edit('perl.h', "# define SAVE_DEFSV                \\\n", "# define SAVE_DEFSV (PL_wump_task ? Perl_wump_save_defsv(aTHX) : (void)WUMP_ROOT_SAVE_DEFSV)\n# define WUMP_ROOT_SAVE_DEFSV       \\\n");
edit('pp.c', "S_localise_gv_slot(pTHX_ GV *gv, U8 type)\n{",
	"S_localise_gv_slot(pTHX_ GV *gv, U8 type)\n{\n    if (PL_wump_task) croak(\"Wump: reference alias localization in a task is not supported yet\");");
for my $file ('pp.c', 'pp_hot.c') {
	my @ops = $file eq 'pp.c' ? qw(aslice hslice) : qw(aelem helem multideref);
	for my $op (@ops) {
		my $start = "PP(pp_$op)\n{";
		edit($file, $start, "$start\n    Perl_wump_local_elements_check(aTHX);");
	}
}
edit('pp.c', "S_do_delete_local(pTHX)\n{",
	"S_do_delete_local(pTHX)\n{\n    Perl_wump_local_elements_check(aTHX);");
edit('run.c', '#define PERL_IN_RUN_C', "#define PERL_IN_RUN_C\n/* Wump core implementation is built into both perl and miniperl. */");
edit('run.c', "Perl_runops_standard(pTHX)\n{",
	"Perl_runops_standard(pTHX)\n{\n    if (PL_wump_task) return Perl_wump_runops(aTHX);");
edit('dump.c', "Perl_runops_debug(pTHX)\n{",
	"Perl_runops_debug(pTHX)\n{\n    unsigned wump_ticks = 256;");
edit('dump.c', '    } while ((PL_op = PL_op->op_ppaddr(aTHX)));',
	"        if (--wump_ticks == 0) {\n            wump_ticks = 256;\n            Perl_wump_checkpoint(aTHX);\n        }\n    } while ((PL_op = PL_op->op_ppaddr(aTHX)));");
my $run = read_file("$source/run.c");
my $include = "\n#include \"wump_core.c\"\n";
write_file("$source/run.c", $run . $include) unless index($run, $include) >= 0;
edit('perl.c', 'boot_core_UNIVERSAL();', "boot_core_UNIVERSAL();\n    Perl_wump_boot(aTHX);");
edit('perl.c', "perl_run(pTHXx)\n{",
	"perl_run(pTHXx)\n{\n    if (aTHX->Iwump_enabled && !PL_wump_task) return Perl_wump_main(aTHX);");
edit('pp_sort.c', "                save_gp(PL_firstgv, 0);\n                save_gp(PL_secondgv, 0);",
	"                if (PL_wump_task) {\n                    save_scalar(PL_firstgv);\n                    save_scalar(PL_secondgv);\n                } else {\n                    save_gp(PL_firstgv, 0);\n                    save_gp(PL_secondgv, 0);\n                }");
edit('pp_ctl.c', "    write_to_stderr(exceptsv);\n    my_failure_exit();",
	"    if (PL_wump_task && PL_wump_task->main && PL_wump_task->finished != 2) {\n        Perl_wump_panic(aTHX_ exceptsv);\n        my_exit(2);\n    }\n    write_to_stderr(exceptsv);\n    my_failure_exit();");
edit('op.h', "    OP *\top_code_list;\t/* list of (?{}) code blocks */",
	"    OP *\top_code_list;\t/* list of (?{}) code blocks */\n    U64 op_wump_id;\n    U8 op_wump_runtime;");
edit('op.h', "#define PM_GETRE_raw(o)\t(REGEXP*)(PL_regex_pad[(o)->op_pmoffset])",
	"#define PM_GETRE_raw(o)\t(REGEXP*)(PL_regex_pad[(o)->op_pmoffset])\n/* Wump keeps compiler ownership in op.c and isolates execution below. */");
my $op = read_file("$source/op.h");
my $macros = <<'C';
/* Wump regex execution slots; op.c always owns the original templates. */
#if defined(USE_ITHREADS) && !defined(PERL_IN_OP_C)
#undef PM_GETRE_raw
#undef PM_GETRE
#undef PM_SETRE_raw
#undef PM_SETRE
#define PM_GETRE_raw(o) ((REGEXP *)*Perl_wump_pm_slot(aTHX_ (PMOP *)(o)))
#define PM_GETRE(o) Perl_wump_pm_get(aTHX_ (PMOP *)(o))
#define PM_SETRE_raw(o,r) STMT_START { \
    *Perl_wump_pm_slot(aTHX_ (PMOP *)(o)) = MUTABLE_SV(r); \
} STMT_END
#define PM_SETRE(o,r) STMT_START { \
    REGEXP *const _wump_rx = (r); \
    assert(_wump_rx); \
    PM_SETRE_raw(o, _wump_rx); \
} STMT_END
#endif
C
my $anchor = '/* Currently these PMf flags occupy a single 32-bit word.';
unless (index($op, $macros) >= 0) {
	$op =~ s/\Q$anchor\E/$macros\n$anchor/ or die "op.h: missing PM flag anchor\n";
	write_file("$source/op.h", $op);
}
edit('op.c', 'NewOp(1101, pmop, 1, PMOP);',
	"NewOp(1101, pmop, 1, PMOP);\n    Perl_wump_pm_stamp(aTHX_ pmop);");
edit('op.c', '/* runtime pattern: build chain of regcomp etc ops */',
	"/* runtime pattern: build chain of regcomp etc ops */\n        pm->op_wump_runtime = 1;");
edit('regexec.c', 'Newxz(PL_reg_curpm, 1, PMOP);',
	"Newxz(PL_reg_curpm, 1, PMOP);\n        Perl_wump_pm_stamp(aTHX_ PL_reg_curpm);");
my $exec = read_file("$source/regexec.c");
$exec =~ s/hv_iterinit\(RXp_PAREN_NAMES\((prog|rx)\)\)/hv_iterinit(Perl_wump_regex_names(aTHX_ RXp_PAREN_NAMES($1)))/g;
$exec =~ s/HV \*hv\s*= RXp_PAREN_NAMES\(rx\);/HV *hv = Perl_wump_regex_names(aTHX_ RXp_PAREN_NAMES(rx));/g;
write_file("$source/regexec.c", $exec);
edit('regexec.c', 'U8 flags = (CXp_SUB_RE |',
	"Perl_wump_cv_prepare(aTHX_ newcv);\n                    U8 flags = (CXp_SUB_RE |");
edit('pp_hot.c', 'truebase = prog->mother_re',
	'truebase = (prog->mother_re && !Perl_wump_pm_native(aTHX_ pm, rx))');
my $hot = read_file("$source/pp_hot.c");
$hot =~ s/!RX_PRELEN\(rx\) && PL_curpm && !prog->mother_re/!RX_PRELEN(rx) \&\& PL_curpm \&\& (!prog->mother_re || Perl_wump_pm_native(aTHX_ pm, rx))/g;
$hot =~ s/\QPL_regex_pad[pm->op_pmoffset]\E/*Perl_wump_pm_slot(aTHX_ pm)/g;
$hot =~ s/\QPL_regex_pad[dynpm->op_pmoffset]\E/*Perl_wump_pm_slot(aTHX_ dynpm)/g;
write_file("$source/pp_hot.c", $hot);
edit('sv.c', 'SvREADONLY_off(PL_regex_pad[(*pmp)->op_pmoffset]);',
	'SvREADONLY_off(*Perl_wump_pm_slot(aTHX_ *pmp));');
require "$FindBin::Bin/elements.pl";
apply_elements($source);
require "$FindBin::Bin/pocket.pl";
apply_pocket($source);
require "$FindBin::Bin/magic.pl";
apply_magic($source);
require "$FindBin::Bin/hooks.pl";
apply_hooks($source);
require "$FindBin::Bin/refcount.pl";
apply_refcount($source);
require "$FindBin::Bin/keys.pl";
apply_keys($source);
require "$FindBin::Bin/reads.pl";
apply_reads($source);
edit('sv.c', "    struct arena_desc set[ARENAS_PER_SET];\n};",
	"    struct arena_desc set[ARENAS_PER_SET];\n};\n#include \"wump_alloc.c\"");
# Debug builds must not race on the arena table's one-time sanity check.
edit('sv.c', "    static bool done_sanity_check;\n\n    if (!done_sanity_check) {",
	"    static _Atomic bool done_sanity_check;\n\n    if (!atomic_exchange_explicit(&done_sanity_check, TRUE, memory_order_relaxed)) {");
edit('sv.c', '        done_sanity_check = TRUE;', '        /* Claimed atomically above. */');
require "$FindBin::Bin/publication.pl";
apply_publication($source);
require "$FindBin::Bin/memory.pl";
apply_memory($source);
require "$FindBin::Bin/opwrites.pl";
apply_opwrites($source);
require "$FindBin::Bin/opreads.pl";
apply_opreads($source);
require "$FindBin::Bin/loads.pl";
apply_loads($source);
require "$FindBin::Bin/materialization.pl";
apply_materialization($source);
require "$FindBin::Bin/parallel.pl";
apply_parallel($source);
require "$FindBin::Bin/regex.pl";
apply_regex($source);
require "$FindBin::Bin/xs.pl";
apply_xs($source);
edit('pp_hot.c', "\n                SvTEMP_off(sv);",
	"\n                if (!PL_wump_task || !Perl_wump_is_shared(aTHX_ sv)) SvTEMP_off(sv);");
edit('toke.c', "Perl_lex_start(pTHX_ SV *line, PerlIO *rsfp, U32 flags)\n{",
	"Perl_lex_start(pTHX_ SV *line, PerlIO *rsfp, U32 flags)\n{\n    if (Perl_wump_parallel(aTHX))\n        croak(\"Wump: runtime compilation is not supported during parallel execution\");");
edit('regcomp.c', '#include "regcomp_internal.h"',
	"#include \"regcomp_internal.h\"\n#include \"wump_regex_roots.c\"");
edit('class.c', '    fields[fieldix] = val;',
	"    Perl_wump_publish_store(aTHX_ instance, val);\n    fields[fieldix] = val;");
{
	my $file = "$source/pp_hot.c";
	my $text = read_file($file);
	my $old = '    if (PL_wump_task && CvISXSUB(cv)) Perl_wump_publish(aTHX_ (SV *)cv);';
	$text =~ s/^\Q$old\E\n//mg;
	my $guard = "    if (PL_wump_task && CvISXSUB(cv)) {\n        Perl_wump_xs_check(aTHX_ cv);\n        Perl_wump_publish(aTHX_ (SV *)cv);\n    }\n";
	if (index($text, $guard) < 0) {
		$text =~ s/^(    if \(!\(CvISXSUB\(cv\)\)\) \{)/$guard$1/m
			or die "missing XS invocation guard anchor\n";
	}
	write_file($file, $text);
}
edit('pp.c', '    SvLOCK(sv);', '    if (PL_wump_task) Perl_wump_lock(aTHX_ sv); else SvLOCK(sv);');
for my $pair (
	["$FindBin::Bin/core/wump_core.c", "$source/wump_core.c"],
	["$FindBin::Bin/core/wump_alloc.c", "$source/wump_alloc.c"],
	["$FindBin::Bin/core/wump_reads.c", "$source/wump_reads.c"],
	["$FindBin::Bin/core/wump_memory.c", "$source/wump_memory.c"],
	["$FindBin::Bin/core/wump_lvalues.c", "$source/wump_lvalues.c"],
	["$FindBin::Bin/core/wump_storage_sv.c", "$source/wump_storage_sv.c"],
	["$FindBin::Bin/core/wump_storage_av.c", "$source/wump_storage_av.c"],
	["$FindBin::Bin/core/wump_storage_hv.c", "$source/wump_storage_hv.c"],
	["$FindBin::Bin/core/wump_keys.c", "$source/wump_keys.c"],
	["$FindBin::Bin/core/wump_local.c", "$source/wump_local.c"],
	["$FindBin::Bin/core/wump_elements.c", "$source/wump_elements.c"],
	["$FindBin::Bin/core/wump_magic.c", "$source/wump_magic.c"],
	["$FindBin::Bin/core/wump_lock.c", "$source/wump_lock.c"],
	["$FindBin::Bin/core/wump_waitgroup.c", "$source/wump_waitgroup.c"],
	["$FindBin::Bin/core/wump_publish.c", "$source/wump_publish.c"],
	["$FindBin::Bin/core/wump_regex_roots.c", "$source/wump_regex_roots.c"],
	["$FindBin::Bin/../runtime/include/wump.h", "$source/wump.h"],
	["$FindBin::Bin/../runtime/src/internal.h", "$source/wump_runtime_internal.h"],
) {
	write_file($pair->[1], read_file($pair->[0]));
}
require "$FindBin::Bin/ordinary.pl";
apply_ordinary($source);
require "$FindBin::Bin/active.pl";
apply_active($source, \@vars);
require "$FindBin::Bin/porting.pl";
apply_porting($source);
print "Applied Wump task-state integration to $source\n";
