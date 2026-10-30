#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdint.h>
#include <pthread.h>
#include <stdatomic.h>
#include "wump.h"

extern OP *Perl_wump_write_impl_preinc(pTHX);

static UV constant_hook_calls;
static OP *hooked_constant(pTHX) {
	__atomic_add_fetch(&constant_hook_calls, 1, __ATOMIC_RELAXED);
	return PL_ppaddr[OP_CONST](aTHX);
}
static bool hook_constant(OP *op) {
	if (!op) return FALSE;
	if (op->op_type == OP_CONST && op->op_ppaddr == PL_ppaddr[OP_CONST]) {
		op->op_ppaddr = hooked_constant;
		return TRUE;
	}
	if (op->op_flags & OPf_KIDS) {
		for (OP *child = cUNOPx(op)->op_first; child; child = OpSIBLING(child))
			if (hook_constant(child)) return TRUE;
	}
	return FALSE;
}
static XS(xs_constant_hook) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items > 1 || (items && PL_wump_task)) croak("Usage: RootFixture::constant_hook([CV outside an act])");
	if (items) {
		if (!SvROK(ST(0)) || SvTYPE(SvRV(ST(0))) != SVt_PVCV) croak("CV reference required");
		if (!hook_constant(CvROOT((CV *)SvRV(ST(0))))) croak("native constant opcode required");
	}
	ST(0) = sv_2mortal(newSVuv(__atomic_load_n(&constant_hook_calls, __ATOMIC_RELAXED)));
	XSRETURN(1);
}

static XS(xs_activate_and_clear) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items || PL_wump_task) croak("Usage: RootFixture::activate_and_clear() outside an act");
	struct wump_perl_task context = {.interp = aTHX, .main = 1};
	Perl_wump_task_activate(aTHX_ &context);
	if (PL_wump_task != &context) abort();
	Perl_wump_task_activate(aTHX_ NULL);
	XSRETURN_EMPTY;
}

static XS(xs_malformed_utf8) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::malformed_utf8()");
	SV *value = newSVpvn("\xc3", 1);
	SvUTF8_on(value);
	ST(0) = sv_2mortal(value);
	XSRETURN(1);
}

static SV *read_target(pTHX_ SV *reference) {
	if (!SvROK(reference)) croak("scalar reference required");
	return SvRV(reference);
}

static XS(xs_execution_context) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::execution_context()");
	AV *state = newAV();
	av_push(state, newSVuv(PTR2UV(aTHX)));
	av_push(state, newSVuv(PTR2UV(PL_wump_task)));
	av_push(state, newSViv(wump_worker_id()));
	av_push(state, newSViv(wump_nprocs()));
	ST(0) = sv_2mortal(newRV_noinc((SV *)state));
	XSRETURN(1);
}

static pthread_once_t executor_once = PTHREAD_ONCE_INIT;
static pthread_barrier_t executor_barrier;
static _Atomic unsigned executor_arrivals;
static unsigned executor_slots;

static void executor_barrier_init(void) {
	executor_slots = (unsigned)wump_nprocs();
	if (pthread_barrier_init(&executor_barrier, NULL, executor_slots)) abort();
}

static XS(xs_executor_rendezvous) {
	dXSARGS;
	if (items || !PL_wump_task) croak("Usage: RootFixture::executor_rendezvous() inside an act");
	if (pthread_once(&executor_once, executor_barrier_init)) abort();
	/* Hold the first job on each slot until all slots have entered. This
	 * makes the distribution check deterministic even under Valgrind. */
	if (atomic_fetch_add_explicit(&executor_arrivals, 1, memory_order_relaxed) < executor_slots) {
		int result = pthread_barrier_wait(&executor_barrier);
		if (result && result != PTHREAD_BARRIER_SERIAL_THREAD) abort();
	}
	xs_execution_context(aTHX_ cv);
}

static XS(xs_metadata_guard) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1 || !SvROK(ST(0)) || SvTYPE(SvRV(ST(0))) != SVt_PVCV)
		croak("Usage: RootFixture::metadata_guard(CALLBACK)");
	ENTER;
	SAVETMPS;
	struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
	PUSHMARK(SP);
	PUTBACK;
	call_sv(ST(0), G_DISCARD);
	Perl_wump_mutation_end(aTHX_ guard);
	FREETMPS;
	LEAVE;
	XSRETURN_EMPTY;
}

static XS(xs_scalar_publish) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1) croak("Usage: RootFixture::scalar_publish(REFERENCE)");
	Perl_wump_publish(aTHX_ read_target(aTHX_ ST(0)));
	XSRETURN_EMPTY;
}

static XS(xs_vivify) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::vivify(REFERENCE, KIND)");
	U32 kind = SvIV(ST(1)) == 0 ? OPpDEREF_SV : SvIV(ST(1)) == 1 ? OPpDEREF_AV : OPpDEREF_HV;
	SV *pad[2] = {NULL, read_target(aTHX_ ST(0))};
	OP op;
	Zero(&op, 1, OP);
	op.op_type = OP_PADSV;
	op.op_flags = OPf_MOD | OPf_WANT_SCALAR;
	op.op_private = kind;
	op.op_targ = 1;
	SSize_t stack_mark = SP - PL_stack_base;
	ENTER;
	SAVEVPTR(PL_curpad);
	SAVEVPTR(PL_op);
	PL_curpad = pad;
	PL_op = &op;
	PUTBACK;
	(void)PL_ppaddr[OP_PADSV](aTHX);
	PL_stack_sp = PL_stack_base + stack_mark;
	LEAVE;
	XSRETURN_EMPTY;
}

static XS(xs_deferred) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 3) croak("Usage: RootFixture::deferred(ARRAY, INDEX, EXTENDIBLE)");
	SV *lv = newSV_type(SVt_PVLV);
	LvTYPE(lv) = 'y';
	sv_magic(lv, NULL, PERL_MAGIC_defelem, NULL, 0);
	LvTARG(lv) = SvREFCNT_inc(read_target(aTHX_ ST(0)));
	LvSTARGOFF(lv) = SvIV(ST(1));
	LvTARGLEN(lv) = SvTRUE(ST(2)) ? 1 : (STRLEN)UV_MAX;
	ST(0) = sv_2mortal(newRV_noinc(lv));
	XSRETURN(1);
}

static XS(xs_lvalue_state) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1) croak("Usage: RootFixture::lvalue_state(REFERENCE)");
	SV *value = read_target(aTHX_ ST(0));
	if (SvTYPE(value) != SVt_PVLV) croak("lvalue reference required");
	AV *state = newAV();
	av_push(state, newSVuv(LvTARGLEN(value)));
	av_push(state, newSViv(LvTARG(value) != NULL));
	ST(0) = sv_2mortal(newRV_noinc((SV *)state));
	XSRETURN(1);
}

static XS(xs_resolve_deferred) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::resolve_deferred(REFERENCE, CREATE)");
	SV *value = read_target(aTHX_ ST(0));
	if (SvTYPE(value) != SVt_PVLV) croak("lvalue reference required");
	if (SvTRUE(ST(1))) Perl_vivify_defelem(aTHX_ value);
	else mg_get(value);
	XSRETURN_EMPTY;
}

static XS(xs_opaque_lvalue) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::opaque_lvalue()");
	SV *value = newSV_type(SVt_PVLV);
	LvTYPE(value) = 't';
	LvTARG(value) = INT2PTR(SV *, 1); /* native fake SV**, deliberately not an SV */
	ST(0) = sv_2mortal(newRV_noinc(value));
	XSRETURN(1);
}

static XS(xs_scalar_state) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1) croak("Usage: RootFixture::scalar_state(REFERENCE)");
	SV *value = read_target(aTHX_ ST(0));
	AV *state = newAV();
	av_push(state, newSVuv(SvFLAGS(value)));
	av_push(state, newSVuv(PTR2UV(SvANY(value))));
	if (SvPOKp(value)) {
		av_push(state, newSVuv(PTR2UV(SvPVX_const(value))));
		av_push(state, newSVuv(SvLEN(value)));
		av_push(state, newSVpvn(SvPVX_const(value), SvCUR(value)));
		av_push(state, newSVuv(SvIsCOW(value) && !SvIsCOW_static(value) && SvLEN(value) ? CowREFCNT(value) : 0));
	}
	ST(0) = sv_2mortal(newRV_noinc((SV *)state));
	XSRETURN(1);
}

static XS(xs_scalar_read) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::scalar_read(REFERENCE, KIND)");
	SV *value = read_target(aTHX_ ST(0));
	IV kind = SvIV(ST(1));
	SV *result;
	STRLEN length;
	char *text;
	switch (kind) {
	case 0: result = newSViv(SvIV(value)); break;
	case 1: result = newSVuv(SvUV(value)); break;
	case 2: result = newSVnv(SvNV(value)); break;
	case 3:
		text = sv_2pv_flags(value, &length, 0);
		result = newSVpvn_flags(text, length, SvUTF8(value) ? SVf_UTF8 : 0);
		break;
	case 4:
		text = sv_2pvbyte_flags(value, &length, 0);
		result = newSVpvn(text, length);
		break;
	case 5:
		text = sv_2pvutf8_flags(value, &length, 0);
		result = newSVpvn_flags(text, length, SVf_UTF8);
		break;
	case 6: result = newSVsv(boolSV(SvTRUE(value))); break;
	case 7: result = newSVsv(value); break;
	case 8:
		text = sv_pvn_force_flags(value, &length, 0);
		result = newSVpvn(text, length);
		break;
	case 9: result = newSVuv(sv_utf8_upgrade(value)); break;
	case 10:
		if (!Perl_wump_readable(aTHX_ value)) croak("not a published plain scalar");
		result = Perl_wump_scalar_snapshot(aTHX_ value);
		break;
	case 11: result = newSVsv(boolSV(SvIsBOOL(value))); break;
	case 12: result = newSViv(SvIV_nomg(value)); break;
	case 13: result = newSVuv(SvUV_nomg(value)); break;
	case 14: result = newSVnv(SvNV_nomg(value)); break;
	case 15: result = newSVsv(boolSV(SvTRUE_nomg(value))); break;
	case 16: result = newSVsv(boolSV(SvTRUE_NN(value))); break;
	case 17: result = newSVsv(boolSV(SvTRUE_nomg_NN(value))); break;
	case 18: result = newSViv(sv_2iv_flags(value, 0)); break;
	case 19: result = newSVuv(sv_2uv_flags(value, 0)); break;
	case 20: result = newSVnv(sv_2nv_flags(value, 0)); break;
	case 21: result = newSVsv(boolSV(sv_2bool_flags(value, 0))); break;
	case 22: text = SvPVbyte(value, length); goto bytes;
	case 23: text = SvPVutf8(value, length); goto encoded;
	case 24: text = SvPV_nomg_nolen(value); length = strlen(text); goto bytes;
	case 25: text = SvPVbyte_or_null(value, length); goto bytes;
	case 26: text = SvPVutf8_or_null(value, length); goto encoded;
	case 27: text = SvPVbyte_nomg(value, length); goto bytes;
	case 28: text = SvPVutf8_nomg(value, length); goto encoded;
	case 29: text = SvPVbyte_nolen(value); length = strlen(text); goto bytes;
	case 30: text = SvPVutf8_nolen(value); length = strlen(text); goto encoded;
	case 31: text = SvPVbyte_or_null_nomg(value, length); goto bytes;
	case 32: text = SvPVutf8_or_null_nomg(value, length); goto encoded;
	case 33: text = (char *)SvPV_const(value, length); goto bytes;
	case 34: text = SvPV_nomg(value, length); goto bytes;
	case 35: result = Perl_wump_scalar_snapshot(aTHX_ value); break;
	case 36: result = newSViv(Perl_wump_readable(aTHX_ value)); break;
	case 37: result = newSVsv(boolSV(Perl_SvTRUE_common(aTHX_ value, FALSE))); break;
	default: croak("unknown scalar read kind");
	}
	goto finish;
bytes:
	result = text ? newSVpvn(text, length) : newSV(0);
	goto finish;
encoded:
	result = text ? newSVpvn_flags(text, length, SVf_UTF8) : newSV(0);
finish:
	ST(0) = sv_2mortal(result);
	XSRETURN(1);
}

static XS(xs_read_frame_active) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::read_frame_active()");
	struct wump_perl_task *task = PL_wump_task;
	ST(0) = boolSV(task ? task->read_frame != NULL : aTHX->Iwump_read_frame != NULL);
	XSRETURN(1);
}

static XS(xs_task_globs) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::task_globs()");
	GV *globs[] = {PL_defgv, PL_errgv, PL_replgv};
	AV *result = newAV();
	for (int i = 0; i < 3; i++) {
		AV *record = newAV();
		av_push(record, newSViv(GvSTASH(globs[i]) == NULL));
		av_push(record, newSViv(GvCVu(globs[i]) == NULL));
		av_push(record, newSVpvn(GvNAME(globs[i]), GvNAMELEN(globs[i])));
		av_push(result, newRV_noinc((SV *)record));
	}
	ST(0) = sv_2mortal(newRV_noinc((SV *)result));
	XSRETURN(1);
}

static XS(xs_namespace_generation) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::namespace_generation()");
	XSRETURN_UV(HvMROMETA(PL_defstash)->pkg_gen);
}

static XS(xs_borrow_read) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::borrow_read(REFERENCE, OTHER)");
	SV *value = read_target(aTHX_ ST(0));
	SV *other = read_target(aTHX_ ST(1));
	STRLEN length, second_length;
	const char *first = sv_2pv_flags(value, &length, SV_CONST_RETURN);
	wump_yield();
	(void)sv_2pv_flags(other, &second_length, SV_CONST_RETURN);
	ST(0) = sv_2mortal(newSVpvn(first, length));
	XSRETURN(1);
}

static void memory_callback(pTHX_ SV *code) {
	dSP;
	ENTER;
	SAVETMPS;
	PUSHMARK(SP);
	PUTBACK;
	call_sv(code, G_DISCARD);
	FREETMPS;
	LEAVE;
}

static XS(xs_memory_stats) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items) croak("Usage: RootFixture::memory_stats()");
	size_t pins, retired, nodes;
	Perl_wump_memory_stats(aTHX_ &pins, &retired, &nodes);
	AV *result = newAV();
	av_push(result, newSVuv(pins));
	av_push(result, newSVuv(retired));
	av_push(result, newSVuv(nodes));
	ST(0) = sv_2mortal(newRV_noinc((SV *)result));
	XSRETURN(1);
}

static XS(xs_memory_replace) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items < 2 || items > 3) croak("Usage: RootFixture::memory_replace(REFERENCE, VALUE [, MAGIC])");
	SV *target = read_target(aTHX_ ST(0));
	STRLEN length;
	const char *text = SvPV_const(ST(1), length);
	if (items == 3 && SvTRUE(ST(2))) sv_setpvn_mg(target, text, length);
	else sv_setpvn(target, text, length);
	XSRETURN_EMPTY;
}

static void memory_free_replacement(pTHX_ void *arg) {
	SvREFCNT_dec(*(SV **)arg);
}

static XS(xs_scalar_write) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items < 2 || items > 3) croak("Usage: RootFixture::scalar_write(REFERENCE, KIND [, VALUE])");
	SV *value = read_target(aTHX_ ST(0));
	IV kind = SvIV(ST(1));
	SV *result = NULL;
	switch (kind) {
	case 0: sv_inc(value); break;
	case 1: sv_dec(value); break;
	case 2: sv_inc_nomg(value); break;
	case 3: sv_dec_nomg(value); break;
	case 4: sv_utf8_encode(value); break;
	case 5: result = newSVsv(boolSV(sv_utf8_decode(value))); break;
	case 6: result = newSVsv(boolSV(sv_utf8_downgrade_flags(value, FALSE, SV_GMAGIC))); break;
	case 7: {
		if (items != 3) croak("replacement value required");
		SV *replacement = NULL;
		ENTER;
		SAVEDESTRUCTOR_X(memory_free_replacement, &replacement);
		replacement = newSVsv(ST(2));
		sv_replace(value, replacement);
		replacement = NULL;
		LEAVE;
		break;
	}
	case 8: result = newSViv(sv_2iv_flags(value, SV_GMAGIC | SV_MUTABLE_RETURN)); break;
	case 9: result = newSVuv(sv_2uv_flags(value, SV_GMAGIC | SV_MUTABLE_RETURN)); break;
	case 10: result = newSVnv(sv_2nv_flags(value, SV_GMAGIC | SV_MUTABLE_RETURN)); break;
	case 11: result = newSVsv(boolSV(sv_utf8_downgrade_flags(value, TRUE, SV_GMAGIC))); break;
	default: croak("unknown scalar write kind");
	}
	ST(0) = sv_2mortal(result ? result : newSVsv(value));
	XSRETURN(1);
}

static XS(xs_unguarded_increment) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1) croak("Usage: RootFixture::unguarded_increment(REFERENCE)");
	SV *value = read_target(aTHX_ ST(0));
	OP op;
	Zero(&op, 1, OP);
	op.op_type = OP_PREINC;
	op.op_flags = OPf_WANT_SCALAR;
	SSize_t opcode_stack_mark = SP - PL_stack_base;
	ENTER;
	SAVEVPTR(PL_op);
	XPUSHs(value);
	PUTBACK;
	PL_op = &op;
	(void)Perl_wump_write_impl_preinc(aTHX);
	PL_stack_sp = PL_stack_base + opcode_stack_mark;
	LEAVE;
	XSRETURN_EMPTY;
}

static XS(xs_memory_guard) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::memory_guard(REFERENCE, CODE)");
	struct wump_mutation *guard = Perl_wump_mutation_begin(aTHX_ read_target(aTHX_ ST(0)));
	memory_callback(aTHX_ ST(1));
	Perl_wump_mutation_end(aTHX_ guard);
	XSRETURN_EMPTY;
}

static XS(xs_memory_borrow) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 3) croak("Usage: RootFixture::memory_borrow(REFERENCE, KIND, CODE)");
	SV *value = read_target(aTHX_ ST(0));
	IV kind = SvIV(ST(1));
	SV *result;
	if (kind == 0 || kind == 3 || kind == 4) {
		STRLEN length;
		const char *text = kind == 3 ? SvPVbyte(value, length)
			: kind == 4 ? SvPVutf8(value, length) : SvPV_const(value, length);
		memory_callback(aTHX_ ST(2));
		result = newSVpvn_flags(text, length, kind == 4 ? SVf_UTF8 : 0);
	} else if (kind == 1) {
		SV **slot = Perl_wump_borrow_av(aTHX_ (AV *)value, 0);
		memory_callback(aTHX_ ST(2));
		result = slot && *slot ? newSVsv(*slot) : newSV(0);
	} else if (kind == 2) {
		HE *entry = Perl_wump_borrow_hv(aTHX_ (HV *)value, "key", 3, 0);
		memory_callback(aTHX_ ST(2));
		result = entry && HeVAL(entry) ? newSVsv(HeVAL(entry)) : newSV(0);
	} else croak("unknown memory borrow kind");
	ST(0) = sv_2mortal(result);
	XSRETURN(1);
}

static XS(xs_memory_container) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::memory_container(REFERENCE, KIND)");
	SV *target = read_target(aTHX_ ST(0));
	IV kind = SvIV(ST(1));
	if (kind == 0) av_store((AV *)target, 0, newSVpvs("new array"));
	else if (kind == 1) {
		SV *removed = av_shift((AV *)target);
		SvREFCNT_dec(removed);
		av_extend((AV *)target, 4096);
	} else if (kind == 2) {
		hv_delete((HV *)target, "key", 3, G_DISCARD);
		hv_store((HV *)target, "key", 3, newSVpvs("new hash"), 0);
		hv_ksplit((HV *)target, 4096);
	} else if (kind == 3) av_clear((AV *)target);
	else if (kind == 4) hv_clear((HV *)target);
	else croak("unknown container mutation kind");
	XSRETURN_EMPTY;
}

static XS(xs_key_too_large) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 0) croak("Usage: RootFixture::key_too_large()");
	(void)Perl_share_hek(aTHX_ "x", (SSize_t)I32_MAX + 1, 0);
	XSRETURN_EMPTY;
}

static XS(xs_key_missing) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items > 1) croak("Usage: RootFixture::key_missing([UTF8])");
	bool utf8 = items && SvTRUE(ST(0));
	const char *text = utf8 ? "wump-missing-\xc3\xa9" : "wump-missing-native-key";
	I32 len = strlen(text);
	U32 hash;
	PERL_HASH(hash, text, len);
	unsharepvn(text, utf8 ? -len : len, hash);
	XSRETURN_EMPTY;
}

static XS(xs_debug_runops) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 0) croak("Usage: RootFixture::debug_runops()");
	PL_runops = Perl_runops_debug;
	XSRETURN_EMPTY;
}

static XS(xs_payload) {
	dXSARGS;
	PERL_UNUSED_VAR(items);
	if (!CvREFCOUNTED_ANYSV(cv)) XSRETURN_UNDEF;
	ST(0) = sv_2mortal(newSVsv(CvXSUBANY(cv).any_sv));
	XSRETURN(1);
}

static XS(xs_make) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 2) croak("Usage: RootFixture::make(VALUE, KIND)");
	IV kind = SvIV(ST(1));
	CV *result;
	if (kind == 2) result = newCONSTSUB(NULL, NULL, newSVsv(ST(0)));
	else if (kind == 3) {
		if (!SvROK(ST(0)) || SvTYPE(SvRV(ST(0))) != SVt_PVAV)
			croak("list constant requires an array reference");
		result = newCONSTSUB(NULL, NULL, SvREFCNT_inc(SvRV(ST(0))));
	} else {
		result = newXS(NULL, xs_payload, __FILE__);
		if (kind == 1) {
			CvXSUBANY(result).any_sv = newSVsv(ST(0));
			CvREFCOUNTED_ANYSV_on(result);
		} else CvXSUBANY(result).any_ptr = (void *)(uintptr_t)1;
	}
	ST(0) = sv_2mortal(newRV_noinc((SV *)result));
	XSRETURN(1);
}

static void fixture_regex_free(pTHX_ REGEXP *rx) {
	PERL_UNUSED_CONTEXT;
	PERL_UNUSED_ARG(rx);
}

static const regexp_engine fixture_regex_engine = { .rxfree = fixture_regex_free };

static XS(xs_constructor_self) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	PERL_UNUSED_VAR(items);
	/* Perl's generated initfields CV keeps its implicit self in pad slot 1.
	 * Model native code letting an instance escape during construction. */
	SV *self = PAD_SVl(1);
	if (!SvROK(self) || SvTYPE(SvRV(self)) != SVt_PVOBJ)
		croak("constructor_self must be called from a field initializer");
	ST(0) = sv_2mortal(newSVsv(self));
	XSRETURN(1);
}

static XS(xs_opaque_regex) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1 || !SvROK(ST(0)) || SvTYPE(SvRV(ST(0))) != SVt_PVCV)
		croak("opaque_regex requires a code reference");
	REGEXP *rx = (REGEXP *)newSV_type(SVt_REGEXP);
	regexp *body = ReANY(rx);
	body->engine = &fixture_regex_engine;
	body->pprivate = (void *)(uintptr_t)1;
	body->qr_anoncv = (CV *)SvREFCNT_inc(SvRV(ST(0)));
	ST(0) = sv_2mortal(newRV_noinc((SV *)rx));
	XSRETURN(1);
}

XS_EXTERNAL(boot_RootFixture) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	PERL_UNUSED_VAR(items);
	newXS("RootFixture::make", xs_make, __FILE__);
	newXS("RootFixture::malformed_utf8", xs_malformed_utf8, __FILE__);
	Perl_wump_xs_allow(aTHX_ newXS("RootFixture::execution_context", xs_execution_context, __FILE__));
	Perl_wump_xs_allow(aTHX_ newXS("RootFixture::executor_rendezvous", xs_executor_rendezvous, __FILE__));
	newXS("RootFixture::metadata_guard", xs_metadata_guard, __FILE__);
	newXS("RootFixture::opaque_regex", xs_opaque_regex, __FILE__);
	newXS("RootFixture::constructor_self", xs_constructor_self, __FILE__);
	newXS("RootFixture::debug_runops", xs_debug_runops, __FILE__);
	newXS("RootFixture::key_too_large", xs_key_too_large, __FILE__);
	newXS("RootFixture::activate_and_clear", xs_activate_and_clear, __FILE__);
	Perl_wump_xs_allow(aTHX_ newXS("RootFixture::constant_hook", xs_constant_hook, __FILE__));
	newXS("RootFixture::key_missing", xs_key_missing, __FILE__);
	newXS("RootFixture::scalar_publish", xs_scalar_publish, __FILE__);
	newXS("RootFixture::vivify", xs_vivify, __FILE__);
	newXS("RootFixture::deferred", xs_deferred, __FILE__);
	newXS("RootFixture::lvalue_state", xs_lvalue_state, __FILE__);
	newXS("RootFixture::resolve_deferred", xs_resolve_deferred, __FILE__);
	newXS("RootFixture::opaque_lvalue", xs_opaque_lvalue, __FILE__);
	newXS("RootFixture::scalar_state", xs_scalar_state, __FILE__);
	newXS("RootFixture::scalar_read", xs_scalar_read, __FILE__);
	newXS("RootFixture::read_frame_active", xs_read_frame_active, __FILE__);
	newXS("RootFixture::task_globs", xs_task_globs, __FILE__);
	newXS("RootFixture::namespace_generation", xs_namespace_generation, __FILE__);
	newXS("RootFixture::borrow_read", xs_borrow_read, __FILE__);
	newXS("RootFixture::memory_stats", xs_memory_stats, __FILE__);
	newXS("RootFixture::memory_replace", xs_memory_replace, __FILE__);
	newXS("RootFixture::scalar_write", xs_scalar_write, __FILE__);
	newXS("RootFixture::unguarded_increment", xs_unguarded_increment, __FILE__);
	newXS("RootFixture::memory_guard", xs_memory_guard, __FILE__);
	newXS("RootFixture::memory_borrow", xs_memory_borrow, __FILE__);
	newXS("RootFixture::memory_container", xs_memory_container, __FILE__);
	XSRETURN_YES;
}
