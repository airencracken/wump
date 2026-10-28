/* Included by sv.c. This first read barrier covers published plain scalars.
 * References, overload, non-publication magic and concurrent writers still
 * need their own protocols. Publication must finish before readers start. */
struct wump_read_frame {
	const SV *source;
	SV *copy;
	struct wump_read_frame *previous;
};

static struct wump_read_frame **wump_read_frames(pTHX) {
	struct wump_perl_task *task = PL_wump_task;
	return task ? &task->read_frame : &aTHX->Iwump_read_frame;
}

bool Perl_wump_readable(pTHX_ const SV *value) {
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

SV *Perl_wump_scalar_snapshot(pTHX_ const SV *value) {
	assert(Perl_wump_readable(aTHX_ value));
	if (SvIsBOOL(value)) return newSVsv(boolSV(SvTRUE_nomg((SV *)value)));
	SV *copy = newSV_type(SVt_PVNV);
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
	return copy;
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
