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

struct wump_operands {
	struct wump_read_frame frames[2];
	struct wump_read_frame *previous;
	SV *sources[2];
	I32 mark, top;
	bool active;
};

static bool wump_operand_plain(pTHX_ SV *value, bool *copy) {
	struct wump_shared *claim = Perl_wump_read_begin(aTHX_ value);
	bool plain = value && SvTYPE(value) <= SVt_PVMG && SvTYPE(value) != SVt_INVLIST
		&& !SvROK(value) && !SvOBJECT(value) && !SvVALID(value);
	if (plain && SvTYPE(value) >= SVt_PVMG) {
		for (MAGIC *mg = SvMAGIC(value); mg; mg = mg->mg_moremagic) {
			if (!Perl_wump_publish_magic(mg)) { plain = FALSE; break; }
		}
	}
	*copy = plain && !SvIMMORTAL(value) && Perl_wump_is_shared(aTHX_ value);
	Perl_wump_read_end(aTHX_ claim);
	return plain;
}

static void wump_operands_release(pTHX_ struct wump_operands *guard) {
	if (!guard->active) return;
	guard->active = FALSE;
	*wump_read_frames(aTHX) = guard->previous;
	SvREFCNT_dec(guard->sources[1]);
	SvREFCNT_dec(guard->sources[0]);
}

static void wump_operands_unwind(pTHX_ void *arg) {
	struct wump_operands *guard = (struct wump_operands *)arg;
	wump_operands_release(aTHX_ guard);
	Safefree(guard);
}

struct wump_operands *Perl_wump_operands_begin(pTHX_ SV *target) {
	SV *sources[2] = {PL_stack_sp[-1], PL_stack_sp[0]};
	bool copies[2] = {FALSE, FALSE};
	/* Check both under short claims, without invoking GET or overload. A
	 * callback must still receive the original SV aliases on native paths. */
	bool left = wump_operand_plain(aTHX_ sources[0], &copies[0]);
	bool right = wump_operand_plain(aTHX_ sources[1], &copies[1]);
	if (!left || !right) return NULL;
	/* Publication can complete between the two classifications. Aliased
	 * stack inputs must still agree on whether they use a captured value. */
	if (sources[0] == sources[1]) copies[0] = copies[1] = copies[0] || copies[1];
	for (int i = 0; i < 2; i++) if (sources[i] == target) copies[i] = FALSE;
	if (!copies[0] && !copies[1]) return NULL;

	SSCHECK(3);
	struct wump_operands *guard;
	Newxz(guard, 1, struct wump_operands);
	guard->previous = *wump_read_frames(aTHX);
	guard->active = TRUE;
	guard->mark = PL_savestack_ix;
	SAVEDESTRUCTOR_X(wump_operands_unwind, guard);
	guard->top = PL_savestack_ix;
	/* Capture all inputs before changing the operand stack. Copies retain
	 * original cache/boolean semantics, but own their bodies and PVs. */
	for (int i = 0; i < 2; i++) {
		if (!copies[i]) continue;
		guard->sources[i] = SvREFCNT_inc(sources[i]);
		SV *copy = i && sources[0] == sources[1] ? guard->frames[0].copy
			: sv_2mortal(Perl_wump_scalar_snapshot(aTHX_ sources[i]));
		struct wump_read_frame *frame = &guard->frames[i];
		frame->source = sources[i];
		frame->copy = copy;
		frame->previous = *wump_read_frames(aTHX);
		*wump_read_frames(aTHX) = frame;
	}
	for (int i = 0; i < 2; i++) {
		if (copies[i]) rpp_replace_at_NN(PL_stack_sp - 1 + i, guard->frames[i].copy);
	}
	return guard;
}

void Perl_wump_operands_end(pTHX_ struct wump_operands *guard) {
	if (!guard) return;
	I32 mark = guard->mark, top = guard->top;
	wump_operands_release(aTHX_ guard);
	/* An opcode may leave caller-owned saves. Keep an inactive heap record
	 * underneath them rather than leaving a C-stack address after return. */
	if (PL_savestack_ix == top) LEAVE_SCOPE(mark);
}
