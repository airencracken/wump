/* Included by sv.c. Short claims protect cache fields and eligibility tests.
 * Exception-safe capture tokens protect allocating snapshots without adding
 * save records while core callers assemble localization records. */
struct wump_read_frame {
	const SV *source;
	SV *copy;
	struct wump_read_frame *previous;
};

static struct wump_read_frame **wump_read_frames(pTHX) {
	struct wump_perl_task *task = PL_wump_task;
	return task ? &task->read_frame : &aTHX->Iwump_read_frame;
}

static bool wump_readable_raw(pTHX_ const SV *value) {
	if (!value || SvTYPE(value) > SVt_PVMG || SvTYPE(value) == SVt_INVLIST
		|| SvROK(value) || SvOBJECT(value)
		|| SvIMMORTAL(value) || SvVALID(value) || PL_phase == PERL_PHASE_DESTRUCT
		|| !PL_curstackinfo) return FALSE;
	if (!Perl_wump_is_shared(aTHX_ value)) return FALSE;
	if (SvTYPE(value) >= SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic)
			if (!Perl_wump_publish_magic(mg)) return FALSE;
	}
	return TRUE;
}

bool Perl_wump_readable(pTHX_ const SV *value) {
	struct wump_shared *claim = Perl_wump_read_begin(aTHX_ value);
	/* A registered shared value with no reader claim belongs to this act's
	 * active writer. Core mutators rely on conversion caches being installed
	 * on that original SV. Explicit snapshots still use the raw eligibility
	 * predicate and remain available inside a mutation. */
	bool owned = PL_wump_task && !claim && Perl_wump_memory_shared(aTHX_ value) == 2;
	bool result = !owned && wump_readable_raw(aTHX_ value);
	Perl_wump_read_end(aTHX_ claim);
	return result;
}

#define WUMP_CACHE_READ(type, name, predicate, raw, backend) \
type Perl_wump_cache_##name(pTHX_ SV *value, I32 flags) { \
	struct wump_shared *claim = Perl_wump_read_begin(aTHX_ value); \
	bool cached = flags & SV_GMAGIC ? predicate##_nog(value) : predicate(value); \
	if (cached) { \
		type result = raw(value); \
		Perl_wump_read_end(aTHX_ claim); \
		return result; \
	} \
	Perl_wump_read_end(aTHX_ claim); \
	return backend(aTHX_ value, flags); \
}
WUMP_CACHE_READ(IV, iv, SvIOK, SvIVX, Perl_sv_2iv_flags)
WUMP_CACHE_READ(UV, uv, SvUOK, SvUVX, Perl_sv_2uv_flags)
WUMP_CACHE_READ(NV, nv, SvNOK, SvNVX, Perl_sv_2nv_flags)
#undef WUMP_CACHE_READ

bool Perl_wump_cache_truth(pTHX_ SV *value, I32 flags, bool fallback) {
	if (!value) return FALSE;
	struct wump_shared *claim = Perl_wump_read_begin(aTHX_ value);
	if ((flags & SV_GMAGIC) && SvGMAGICAL(value)) {
		Perl_wump_read_end(aTHX_ claim);
		/* FETCH may throw, park, or mutate the scalar. Reacquire only after
		 * it returns; the short claim never spans a user callback. */
		SvGETMAGIC(value);
		claim = Perl_wump_read_begin(aTHX_ value);
	}
	bool result;
	if (SvIMMORTAL_INTERP(value)) result = SvIMMORTAL_TRUE(value);
	else if (!SvOK(value)) result = FALSE;
	else if (SvPOK(value)) result = SvPVXtrue(value);
	else if (SvIOK(value)) result = SvIVX(value) != 0;
	else if (SvROK(value) && !(SvOBJECT(SvRV(value)) && HvAMAGIC(SvSTASH(SvRV(value))))) result = TRUE;
	else {
		result = isGV_with_GP(value);
		Perl_wump_read_end(aTHX_ claim);
		return fallback ? Perl_sv_2bool_flags(aTHX_ value, 0) : result;
	}
	Perl_wump_read_end(aTHX_ claim);
	return result;
}

SV *Perl_wump_scalar_snapshot(pTHX_ const SV *value) {
	struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ value);
	if (!wump_readable_raw(aTHX_ value)) {
		Perl_wump_capture_end(aTHX_ capture);
		croak("Wump: shared scalar representation changed during snapshot capture");
	}
	/* Root the new copy before allocating its PV. The holder keeps failure
	 * cleanup on the temporary stack, preserving the no-save-record contract. */
	SV *holder = sv_2mortal(newSV_type(SVt_IV));
	SV *copy = SvIsBOOL(value) ? newSVsv(boolSV(SvTRUE_nomg((SV *)value))) : newSV_type(SVt_PVNV);
	SvRV_set(holder, copy);
	SvROK_on(holder);
	if (SvIsBOOL(value)) {
		Perl_wump_capture_end(aTHX_ capture);
		return SvREFCNT_inc(copy);
	}
	U32 flags = SvFLAGS(value);
	if (SvPOKp(value))
		sv_setpvn(copy, SvPVX_const(value) ? SvPVX_const(value) : "", SvCUR(value));
	if (SvIOKp(value)) {
		if (SvIsUV(value)) SvUV_set(copy, SvUVX(value));
		else SvIV_set(copy, SvIVX(value));
	}
	if (SvNOKp(value)) SvNV_set(copy, SvNVX(value));
	/* Keep dual-value/cache distinctions, but no ownership, COW, magic,
	 * readonly or temporary flags. The new PV has independent storage. */
	const U32 cache = SVf_IOK | SVp_IOK | SVf_NOK | SVp_NOK
		| SVf_POK | SVp_POK | SVf_IVisUV | SVf_UTF8;
	SvFLAGS(copy) = (SvFLAGS(copy) & ~cache) | (flags & cache);
	Perl_wump_capture_end(aTHX_ capture);
	return SvREFCNT_inc(copy);
}

const SV *Perl_wump_read_origin(pTHX_ const SV *value) {
	for (struct wump_read_frame *frame = *wump_read_frames(aTHX); frame; frame = frame->previous)
		if (frame->copy == value) return frame->source;
	return value;
}

static void wump_read_enter(pTHX_ struct wump_read_frame *frame, SV *source, SV *copy) {
	struct wump_read_frame **slot = wump_read_frames(aTHX);
	frame->source = source;
	frame->copy = copy;
	frame->previous = *slot;
	/* Restore the frame slot before dropping the pin on unwind. */
	SAVEFREESV(SvREFCNT_inc(source));
	SAVEVPTR(*slot);
	*slot = frame;
	/* Hooks can replace the original slot, throw, yield or be abandoned. */
}

#define WUMP_SCALAR_READ(type, kind, convert) \
type Perl_wump_read_##kind(pTHX_ SV *value, I32 flags) { \
	SV *copy = sv_2mortal(Perl_wump_scalar_snapshot(aTHX_ value)); \
	struct wump_read_frame frame; \
	ENTER; \
	wump_read_enter(aTHX_ &frame, value, copy); \
	type result = convert(aTHX_ copy, flags); \
	LEAVE; \
	return result; \
}
WUMP_SCALAR_READ(IV, iv, Perl_sv_2iv_flags)
WUMP_SCALAR_READ(UV, uv, Perl_sv_2uv_flags)
WUMP_SCALAR_READ(NV, nv, Perl_sv_2nv_flags)
WUMP_SCALAR_READ(bool, bool, Perl_sv_2bool_flags)
#undef WUMP_SCALAR_READ

char *Perl_wump_read_pv(pTHX_ SV *value, STRLEN *length, U32 flags, int encoding) {
	SV *copy = sv_2mortal(Perl_wump_scalar_snapshot(aTHX_ value));
	return Perl_wump_read_snapshot_pv(aTHX_ value, copy, length, flags, encoding);
}

char *Perl_wump_read_snapshot_pv(pTHX_ SV *value, SV *copy, STRLEN *length, U32 flags, int encoding) {
	struct wump_read_frame frame;
	ENTER;
	wump_read_enter(aTHX_ &frame, value, copy);
	char *result;
	if (encoding == 1) result = Perl_sv_2pvbyte_flags(aTHX_ copy, length, flags);
	else if (encoding == 2) result = Perl_sv_2pvutf8_flags(aTHX_ copy, length, flags);
	else result = Perl_sv_2pv_flags(aTHX_ copy, length, flags);
	LEAVE;
	/* No SAVETMPS scope here: the returned buffer lives through the caller's
	 * current temporary scope, including switches and nested conversions. */
	return result;
}

void Perl_wump_read_copy(pTHX_ SV *target, SV *value, I32 flags) {
	SV *copy = sv_2mortal(Perl_wump_scalar_snapshot(aTHX_ value));
	/* Plain copies cannot warn or FETCH the source. Do not touch the save
	 * stack: save_helem_flags can copy a key while assembling a save record. */
	Perl_sv_setsv_flags(aTHX_ target, copy, flags & ~SV_GMAGIC);
}
