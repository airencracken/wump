#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdint.h>
#include "wump.h"

static SV *read_target(pTHX_ SV *reference) {
	if (!SvROK(reference)) croak("scalar reference required");
	return SvRV(reference);
}

static XS(xs_scalar_publish) {
	dXSARGS;
	PERL_UNUSED_VAR(cv);
	if (items != 1) croak("Usage: RootFixture::scalar_publish(REFERENCE)");
	Perl_wump_publish(aTHX_ read_target(aTHX_ ST(0)));
	XSRETURN_EMPTY;
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
	newXS("RootFixture::opaque_regex", xs_opaque_regex, __FILE__);
	newXS("RootFixture::constructor_self", xs_constructor_self, __FILE__);
	newXS("RootFixture::debug_runops", xs_debug_runops, __FILE__);
	newXS("RootFixture::key_too_large", xs_key_too_large, __FILE__);
	newXS("RootFixture::key_missing", xs_key_missing, __FILE__);
	newXS("RootFixture::scalar_publish", xs_scalar_publish, __FILE__);
	newXS("RootFixture::scalar_state", xs_scalar_state, __FILE__);
	newXS("RootFixture::scalar_read", xs_scalar_read, __FILE__);
	newXS("RootFixture::read_frame_active", xs_read_frame_active, __FILE__);
	newXS("RootFixture::borrow_read", xs_borrow_read, __FILE__);
	newXS("RootFixture::memory_stats", xs_memory_stats, __FILE__);
	newXS("RootFixture::memory_replace", xs_memory_replace, __FILE__);
	newXS("RootFixture::memory_guard", xs_memory_guard, __FILE__);
	newXS("RootFixture::memory_borrow", xs_memory_borrow, __FILE__);
	newXS("RootFixture::memory_container", xs_memory_container, __FILE__);
	XSRETURN_YES;
}
