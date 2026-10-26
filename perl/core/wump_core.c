/* Built into the private Perl fork; this cannot be loaded into stock Perl.
 * The first bridge uses one execution slot and never clones interpreters. */
#include "XSUB.h"
#include "wump_runtime_internal.h"
#include <math.h>

typedef struct wump_cv_slot {
	CV *cv;
	PADLIST *pad;
	I32 depth;
	struct wump_cv_slot *next;
} wump_cv_slot;

typedef struct wump_perl_message {
	SV *value;
	struct wump_perl_message *next, *previous;
} wump_perl_message;

typedef struct wump_perl_channel {
	UV id;
	wump_chan *ch;
	struct wump_perl_channel *next;
} wump_perl_channel;

typedef struct wump_perl_run {
	wump_perl_channel *channels;
	wump_perl_message *messages;
	SV *panic;
	UV panic_task, next_task;
	int started;
} wump_perl_run;

static wump_perl_run *wump_perl_active;
static UV wump_channel_id;

static wump_cv_slot *wump_cv_find(pTHX_ const CV *cv) {
	if (PL_wump_task != NULL) {
		for (wump_cv_slot *slot = PL_wump_task->cvs; slot != NULL; slot = slot->next) {
			if (slot->cv == cv) return slot;
		}
	}
	return NULL;
}

I32 *Perl_wump_cv_depth(pTHX_ const CV *cv) {
	wump_cv_slot *slot = wump_cv_find(aTHX_ cv);
	return slot != NULL ? &slot->depth : &((XPVCV *)SvANY(cv))->xcv_depth;
}

PADLIST **Perl_wump_cv_padlist(CV *cv) {
	dTHX;
	wump_cv_slot *slot = wump_cv_find(aTHX_ cv);
	return slot != NULL ? &slot->pad : &((XPVCV *)SvANY(cv))->xcv_padlist_u.xcv_padlist;
}

/* Reuse Perl's recursive-pad construction to preserve captured/state
 * lexicals and constants while allocating fresh local variables and @_. */
void Perl_wump_cv_prepare(pTHX_ CV *cv) {
	if (PL_wump_task == NULL || PL_wump_task->finished == 2 ||
		CvISXSUB(cv) || wump_cv_find(aTHX_ cv) != NULL) return;
	PADLIST *original = CvPADLIST(cv);
	if (original == NULL) return;
	wump_cv_slot *slot;
	PADLIST *pad;
	Newxz(slot, 1, wump_cv_slot);
	Newxz(pad, 1, PADLIST);
	Newxz(PadlistARRAY(pad), 2, PAD *);
	PadlistMAX(pad) = 1;
	pad->xpadl_id = original->xpadl_id;
	pad->xpadl_outid = original->xpadl_outid;
	PadlistNAMES(pad) = PadnamelistREFCNT_inc(PadlistNAMES(original));
	PadlistARRAY(pad)[1] = (PAD *)SvREFCNT_inc(PadlistARRAY(original)[1]);
	pad_push(pad, 2);
	SvREFCNT_dec(PadlistARRAY(pad)[1]);
	PadlistARRAY(pad)[1] = PadlistARRAY(pad)[2];
	PadlistARRAY(pad)[2] = NULL;
	/* Keep max=2: the allocated array really has three entries. */
	slot->pad = pad;
	slot->cv = CvREFCNT_inc(cv);
	slot->next = PL_wump_task->cvs;
	PL_wump_task->cvs = slot;
}

SV **Perl_wump_gv_sv(GV *gv) {
	dTHX;
	if (PL_wump_task != NULL) {
		if (gv == aTHX->Idefgv) gv = PL_defgv;
		else if (gv == aTHX->Ierrgv) gv = PL_errgv;
	}
	return &GvGP(gv)->gp_sv;
}

AV **Perl_wump_gv_av(GV *gv) {
	dTHX;
	if (PL_wump_task != NULL && gv == aTHX->Idefgv) gv = PL_defgv;
	return &GvGP(gv)->gp_av;
}

static void wump_perl_enter(void *arg) {
	struct wump_perl_task *task = arg;
	PERL_SET_CONTEXT(task->interp);
	task->interp->Iwump_task = task;
}

static void wump_perl_task_free(void *arg) {
	struct wump_perl_task *task = arg;
	dTHXa(task->interp);
	wump_perl_enter(task);
	if (!task->initialized) {
		/* A queued task has no Perl stacks on which to free its CV. */
		PL_wump_task = NULL;
		SvREFCNT_dec(task->entry);
		Safefree(task);
		return;
	}
	int abandoned = !task->finished;
	/* Destructors may call Perl, but cannot schedule during teardown.
	 * Use ordinary recursive pads for new calls instead of creating
	 * caches that would outlive the list currently being released. */
	task->finished = 2;
	if (task->initialized) {
		/* Abandoned XS frames still have mapped C stacks at this point.
		 * Catch destructor failures locally rather than jumping into one. */
		dJMPENV;
		JMPENV_BOOTSTRAP;
		int jump;
		JMPENV_PUSH(jump);
		if (jump == 0 && abandoned) {
			dounwind(-1);
			LEAVE_SCOPE(0);
			PL_tmps_floor = -1;
			free_tmps();
		}
		JMPENV_POP;
		if (jump != 0) {
			PerlIO_printf(Perl_error_log, "Wump: task destructor failed during shutdown\n");
		}
		/* Stop exposing task padlists before releasing their CV roots. */
		wump_cv_slot *slot = task->cvs;
		task->cvs = NULL;
		while (slot != NULL) {
			wump_cv_slot *next = slot->next;
			for (SSize_t n = PadlistMAX(slot->pad); n > 0; n--) {
				SvREFCNT_dec(PadlistARRAY(slot->pad)[n]);
			}
			PadnamelistREFCNT_dec(PadlistNAMES(slot->pad));
			Safefree(PadlistARRAY(slot->pad));
			Safefree(slot->pad);
			SvREFCNT_dec(slot->cv);
			Safefree(slot);
			slot = next;
		}
		SvREFCNT_dec(task->entry);
		task->entry = NULL;
		GV *defgv = PL_defgv;
		GV *errgv = PL_errgv;
		PL_defgv = aTHX->Idefgv;
		PL_errgv = aTHX->Ierrgv;
		SvREFCNT_dec(defgv);
		SvREFCNT_dec(errgv);
		while (PL_curstackinfo->si_next != NULL) PL_curstackinfo = PL_curstackinfo->si_next;
		while (PL_curstackinfo != NULL) {
			PERL_SI *previous = PL_curstackinfo->si_prev;
			SvREFCNT_dec(PL_curstackinfo->si_stack);
			Safefree(PL_curstackinfo->si_cxstack);
			Safefree(PL_curstackinfo);
			PL_curstackinfo = previous;
		}
		Safefree(PL_tmps_stack);
		Safefree(PL_markstack);
		Safefree(PL_scopestack);
#ifdef DEBUGGING
		Safefree(PL_scopestack_name);
#endif
		Safefree(PL_savestack);
		Safefree(PL_reg_curpm);
		regmatch_slab *slab = PL_regmatch_slab;
		while (slab != NULL) {
			regmatch_slab *next = slab->next;
			Safefree(slab);
			slab = next;
		}
	}
	PL_wump_task = NULL;
	Safefree(task);
}

static struct wump_perl_task *wump_perl_task_new(pTHX_ SV *callback) {
	if (!SvROK(callback) || SvTYPE(SvRV(callback)) != SVt_PVCV) croak("Wump: expected a code reference");
	struct wump_perl_task *task;
	Newxz(task, 1, struct wump_perl_task);
	task->interp = aTHX;
	task->entry = CvREFCNT_inc((CV *)SvRV(callback));
	task->Icurcop = PL_curcop;
	task->Icurstash = PL_curstash;
	task->Idefoutgv = PL_defoutgv;
	task->id = ++wump_perl_active->next_task;
	return task;
}

static void wump_perl_task_start(void *arg) {
	struct wump_perl_task *task = arg;
	dTHXa(task->interp);
	wump_perl_enter(task);
	if (task->id == 1) {
		wump_perl_active->started = 1;
		if (wump_context_attach(wump_perl_enter, wump_perl_task_free, task) != 0) abort();
	}
	JMPENV_BOOTSTRAP;
	init_stacks();
	task->initialized = 1;
	PL_defgv = (GV *)newSV_type(SVt_PVGV);
	gv_init(PL_defgv, PL_defstash, "_", 1, 0);
	if (GvSV(PL_defgv) == NULL) GvSV(PL_defgv) = newSV(0);
	GvAV(PL_defgv) = newAV();
	PL_errgv = (GV *)newSV_type(SVt_PVGV);
	gv_init(PL_errgv, PL_defstash, "@", 1, 0);
	if (GvSV(PL_errgv) == NULL) GvSV(PL_errgv) = newSVpvs("");
	{
		dSP;
		ENTER;
		SAVETMPS;
		PUSHMARK(SP);
		PUTBACK;
		call_sv((SV *)task->entry, G_DISCARD | G_EVAL);
		if (SvTRUE(ERRSV) || SvROK(ERRSV)) {
			if (wump_perl_active->panic == NULL) {
				wump_perl_active->panic = newSVsv(ERRSV);
				wump_perl_active->panic_task = task->id;
			}
			wump_halt(ECANCELED);
		}
		FREETMPS;
		LEAVE;
	}
	task->finished = 1;
}

static void xs_wump_run(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: Wump::run(CODE)");
	if (wump_perl_active != NULL || PL_wump_task != NULL) croak("Wump: nested runs are unsupported");
	wump_perl_run run = {0};
	wump_perl_active = &run;
	/* Validate before publishing the stack-owned run record. */
	if (!SvROK(ST(0)) || SvTYPE(SvRV(ST(0))) != SVt_PVCV) {
		wump_perl_active = NULL;
		croak("Wump: expected a code reference");
	}
	struct wump_perl_task *task = wump_perl_task_new(aTHX_ ST(0));
	int result = wump_run(wump_perl_task_start, task, 1);
	int error = wump_errno();
	PL_wump_task = NULL;
	/* Startup can fail before the task has attached its cleanup hook. */
	if (!run.started) {
		SvREFCNT_dec(task->entry);
		Safefree(task);
	}
	wump_perl_active = NULL;
	while (run.channels != NULL) {
		wump_perl_channel *next = run.channels->next;
		wump_chan_free(run.channels->ch);
		Safefree(run.channels);
		run.channels = next;
	}
	while (run.messages != NULL) {
		wump_perl_message *next = run.messages->next;
		SvREFCNT_dec(run.messages->value);
		Safefree(run.messages);
		run.messages = next;
	}
	if (run.panic != NULL) {
		PerlIO_printf(Perl_error_log, "task %" UVuf " [panic]: %s", run.panic_task, SvPV_nolen(run.panic));
		SvREFCNT_dec(run.panic);
		PerlIO_flush(NULL);
		exit(2);
	}
	if (result != 0) croak("Wump: runtime failed: %s", Strerror(error));
	XSRETURN_EMPTY;
}

static void xs_wump_act(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: act requires a running task and a code reference");
	struct wump_perl_task *task = wump_perl_task_new(aTHX_ ST(0));
	if (wump_go_context(wump_perl_task_start, task, wump_perl_enter, wump_perl_task_free) != 0) {
		SvREFCNT_dec(task->entry);
		Safefree(task);
		croak("Wump: spawn failed");
	}
	XSRETURN_EMPTY;
}

static wump_perl_channel *wump_perl_channel_get(pTHX_ SV *object) {
	if (wump_perl_active == NULL || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: channel operation requires a running task");
	if (!SvROK(object) || !sv_derived_from(object, "Wump::Channel") || SvTYPE(SvRV(object)) >= SVt_PVAV) croak("Wump: invalid channel");
	UV id = SvUV(SvRV(object));
	for (wump_perl_channel *ch = wump_perl_active->channels; ch != NULL; ch = ch->next) {
		if (ch->id == id) return ch;
	}
	croak("Wump: channel belongs to an inactive run");
}

static void xs_wump_chan(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: chan requires a running task");
	if (!SvOK(ST(0)) || SvROK(ST(0)) || !looks_like_number(ST(0))) croak("Wump: invalid channel capacity");
	NV capacity = SvNV(ST(0));
	if (!isfinite(capacity) || capacity < 0 || capacity > INT_MAX || capacity != (NV)(IV)capacity) croak("Wump: invalid channel capacity");
	if (wump_channel_id == UV_MAX) croak("Wump: channel id space exhausted");
	wump_perl_channel *ch;
	Newxz(ch, 1, wump_perl_channel);
	ch->ch = wump_chan_make(sizeof(wump_perl_message *), (size_t)capacity);
	if (ch->ch == NULL) { Safefree(ch); croak("Wump: channel allocation failed"); }
	ch->id = ++wump_channel_id;
	ch->next = wump_perl_active->channels;
	wump_perl_active->channels = ch;
	SV *id = newSVuv(ch->id);
	SV *object = newRV_noinc(id);
	sv_bless(object, gv_stashpvs("Wump::Channel", GV_ADD));
	SvREADONLY_on(id);
	ST(0) = sv_2mortal(object);
	XSRETURN(1);
}

static void xs_wump_send(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 2) croak("Usage: CHANNEL->send(VALUE)");
	wump_perl_channel *ch = wump_perl_channel_get(aTHX_ ST(0));
	wump_perl_message *message;
	Newxz(message, 1, wump_perl_message);
	message->next = wump_perl_active->messages;
	if (message->next != NULL) message->next->previous = message;
	wump_perl_active->messages = message;
	message->value = newSVsv(ST(1));
	if (wump_chan_send(ch->ch, &message) != 0) croak("Wump: send on closed channel");
	XSRETURN_EMPTY;
}

static void xs_wump_recv(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: CHANNEL->recv()");
	wump_perl_channel *ch = wump_perl_channel_get(aTHX_ ST(0));
	wump_perl_message *message = NULL;
	int result = wump_chan_recv(ch->ch, &message);
	if (result < 0) croak("Wump: receive failed");
	if (result == 0) {
		ST(0) = &PL_sv_undef;
		if (GIMME_V == G_LIST) { EXTEND(SP, 1); ST(1) = &PL_sv_no; XSRETURN(2); }
		XSRETURN(1);
	}
	ST(0) = sv_2mortal(newSVsv(message->value));
	SvREFCNT_dec(message->value);
	if (message->previous != NULL) message->previous->next = message->next;
	else wump_perl_active->messages = message->next;
	if (message->next != NULL) message->next->previous = message->previous;
	Safefree(message);
	if (GIMME_V == G_LIST) { EXTEND(SP, 1); ST(1) = &PL_sv_yes; XSRETURN(2); }
	XSRETURN(1);
}

static void xs_wump_close(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1) croak("Usage: CHANNEL->close()");
	wump_perl_channel *ch = wump_perl_channel_get(aTHX_ ST(0));
	if (wump_chan_close(ch->ch) != 0) croak("Wump: close of closed channel");
	XSRETURN_EMPTY;
}

static void xs_wump_yield(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 0 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: yield requires a running task");
	wump_yield();
	XSRETURN_EMPTY;
}

static void xs_wump_sleep(pTHX_ CV *cv) {
	dXSARGS;
	if (items != 1 || wump_self() == NULL || PL_wump_task == NULL) croak("Wump: sleep requires a running task");
	if (!SvOK(ST(0)) || SvROK(ST(0)) || !looks_like_number(ST(0))) croak("Wump: invalid sleep duration");
	NV duration = SvNV(ST(0));
	if (!isfinite(duration) || duration < 0 || duration >= (NV)INT64_MAX / 1e9) croak("Wump: invalid sleep duration");
	if (wump_sleep((int64_t)(duration * 1e9)) != 0) croak("Wump: sleep failed");
	XSRETURN_EMPTY;
}

void Perl_wump_boot(pTHX) {
	newXS("Wump::_run", xs_wump_run, __FILE__);
	newXS("Wump::_act", xs_wump_act, __FILE__);
	newXS("Wump::_chan", xs_wump_chan, __FILE__);
	newXS("Wump::_send", xs_wump_send, __FILE__);
	newXS("Wump::_recv", xs_wump_recv, __FILE__);
	newXS("Wump::_close", xs_wump_close, __FILE__);
	newXS("Wump::_yield", xs_wump_yield, __FILE__);
	newXS("Wump::_sleep", xs_wump_sleep, __FILE__);
}
