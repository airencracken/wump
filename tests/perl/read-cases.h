#include "EXTERN.h"
#include "perl.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

enum { read_cases = 14 };
typedef struct read_case {
	SV *value;
	bool numeric;
	IV iv;
	UV uv;
	NV nv;
	const char *pv;
	STRLEN length;
	const char *utf8;
	STRLEN utf8_length;
	const char *bytes;
	STRLEN byte_length;
	bool truth;
	U32 flags;
	void *body;
	const char *buffer;
	STRLEN capacity;
	U8 cow;
} read_case;

static void capture_case(pTHX_ read_case *test) {
	SV *sv = test->value;
	Perl_wump_publish(aTHX_ sv);
	test->flags = SvFLAGS(sv);
	test->body = SvANY(sv);
	if (SvPOKp(sv)) {
		test->buffer = SvPVX_const(sv);
		test->capacity = SvLEN(sv);
		if (SvIsCOW(sv) && !SvIsCOW_static(sv) && SvLEN(sv)) test->cow = CowREFCNT(sv);
	}
}

static void build_cases(pTHX_ read_case *tests, SV **alias) {
	Zero(tests, read_cases, read_case);
	const char *strings[] = {"42", "42.5", "18446744073709551615", "-42", "18446744073709551615", "42.5",
		"", "0", "\xe9", "\xc3\xa9", "\xe2\x82\xac", "seven", "1", "a long independently held copy on write string used by every reader"};
	for (int i = 0; i < read_cases; i++) {
		tests[i].pv = strings[i];
		tests[i].length = strlen(strings[i]);
		tests[i].utf8 = strings[i];
		tests[i].utf8_length = tests[i].length;
		tests[i].bytes = strings[i];
		tests[i].byte_length = tests[i].length;
		tests[i].truth = i != 6 && i != 7;
		tests[i].value = newSVpvn(strings[i], tests[i].length);
	}
	for (int i = 0; i < 6; i++) tests[i].numeric = TRUE;
	tests[0].iv = 42; tests[0].uv = 42; tests[0].nv = 42;
	tests[1].iv = 42; tests[1].uv = 42; tests[1].nv = 42.5;
	tests[2].iv = -1; tests[2].uv = UV_MAX; tests[2].nv = (NV)UV_MAX;
	sv_setiv(tests[3].value, -42);
	tests[3].iv = -42; tests[3].uv = (UV)-42; tests[3].nv = -42;
	sv_setuv(tests[4].value, UV_MAX);
	tests[4].iv = -1; tests[4].uv = UV_MAX; tests[4].nv = (NV)UV_MAX;
	sv_setnv(tests[5].value, 42.5);
	tests[5].iv = 42; tests[5].uv = 42; tests[5].nv = 42.5;
	tests[7].numeric = TRUE;
	tests[8].utf8 = "\xc3\xa9"; tests[8].utf8_length = 2;
	SvUTF8_on(tests[9].value);
	tests[9].bytes = "\xe9"; tests[9].byte_length = 1;
	SvUTF8_on(tests[10].value);
	tests[10].bytes = NULL;
	SvUPGRADE(tests[11].value, SVt_PVNV);
	SvIV_set(tests[11].value, 7);
	SvIOK_on(tests[11].value);
	tests[11].numeric = TRUE; tests[11].iv = 7; tests[11].uv = 7; tests[11].nv = 7;
	sv_setbool(tests[12].value, TRUE);
	tests[12].numeric = TRUE; tests[12].iv = 1; tests[12].uv = 1; tests[12].nv = 1;
	*alias = newSVsv(tests[13].value);
	for (int i = 0; i < read_cases; i++) capture_case(aTHX_ &tests[i]);
}

static void unchanged_case(pTHX_ const read_case *test) {
	SV *sv = test->value;
	CHECK(SvFLAGS(sv) == test->flags && SvANY(sv) == test->body);
	if (SvPOKp(sv)) {
		CHECK(SvPVX_const(sv) == test->buffer && SvLEN(sv) == test->capacity);
		CHECK(SvCUR(sv) == test->length && memEQ(SvPVX_const(sv), test->pv, test->length));
		if (SvIsCOW(sv) && !SvIsCOW_static(sv) && SvLEN(sv)) CHECK(CowREFCNT(sv) == test->cow);
	}
}

static void exercise_case(pTHX_ const read_case *test) {
	SV *sv = test->value;
	if (test->numeric) {
		CHECK(SvIV(sv) == test->iv && sv_2iv_flags(sv, 0) == test->iv);
		CHECK(SvUV(sv) == test->uv && sv_2uv_flags(sv, 0) == test->uv);
		CHECK(SvNV(sv) == test->nv && sv_2nv_flags(sv, 0) == test->nv);
	}
	unchanged_case(aTHX_ test);
	CHECK(SvTRUE(sv) == test->truth && sv_2bool_flags(sv, 0) == test->truth);
	STRLEN length;
	const char *pv = SvPV_const(sv, length);
	CHECK(length == test->length && memEQ(pv, test->pv, length));
	const char *first = sv_2pv_flags(sv, &length, SV_CONST_RETURN);
	CHECK(length == test->length && memEQ(first, test->pv, length));
	/* A later conversion must not replace the earlier returned buffer. */
	pv = sv_2pvutf8_flags(sv, &length, 0);
	CHECK(length == test->utf8_length && memEQ(pv, test->utf8, length));
	if (test->bytes) {
		pv = sv_2pvbyte_flags(sv, &length, 0);
		CHECK(length == test->byte_length && memEQ(pv, test->bytes, length));
	}
	CHECK(memEQ(first, test->pv, test->length));
	SV *copy = newSVsv(sv);
	pv = SvPV_const(copy, length);
	CHECK(length == test->length && memEQ(pv, test->pv, length));
	if (SvIsBOOL(sv)) CHECK(SvIsBOOL(copy));
	sv_setpvs(copy, "private mutation");
	SvREFCNT_dec(copy);
	unchanged_case(aTHX_ test);
}
