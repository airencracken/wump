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
	default: croak("unknown scalar read kind");
	}
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
	XSRETURN_YES;
}
