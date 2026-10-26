#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdint.h>

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
	XSRETURN_YES;
}
