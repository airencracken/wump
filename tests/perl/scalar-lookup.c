#include "EXTERN.h"
#include "perl.h"
#include "../../perl/core/wump_scalar.h"
#include <stdio.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)

static unsigned long public_loads;
static unsigned long hook_calls;
START_EXTERN_C
OP *Perl_pp_gvsv(pTHX);
SV **__real_Perl_wump_gv_sv(GV *gv);
SV **__wrap_Perl_wump_gv_sv(GV *gv) {
	dTHX;
	struct wump_perl_task *task = PL_wump_task;
	if (task && !task->locals && gv == aTHX->Idefgv && PL_op
		&& PL_op->op_type == OP_GVSV && PL_op->op_ppaddr == Perl_pp_gvsv)
		__atomic_fetch_add(&public_loads, 1, __ATOMIC_RELAXED);
	return __real_Perl_wump_gv_sv(gv);
}
END_EXTERN_C

static OP *hooked_scalar(pTHX) {
	__atomic_fetch_add(&hook_calls, 1, __ATOMIC_RELAXED);
	return Perl_pp_gvsv(aTHX);
}

static bool install_hook(OP *op) {
	if (!op) return FALSE;
	if (op->op_type == OP_GVSV && op->op_ppaddr == Perl_pp_gvsv) {
		op->op_ppaddr = hooked_scalar;
		return TRUE;
	}
	if (op->op_flags & OPf_KIDS) {
		for (OP *child = cUNOPx(op)->op_first; child; child = OpSIBLING(child))
			if (install_hook(child)) return TRUE;
	}
	return FALSE;
}

static GV *private_glob(pTHX_ const char *name, STRLEN length) {
	GV *gv = (GV *)newSV(0);
	gv_init(gv, NULL, name, length, 0);
	if (!GvGP(gv)->gp_sv) GvGP(gv)->gp_sv = newSV(0);
	return gv;
}

static void check_slots(pTHX) {
	struct wump_perl_task main_task = {0}, child = {0};
	main_task.interp = child.interp = aTHX;
	main_task.main = 1;
	child.Idefgv = private_glob(aTHX_ "_", 1);
	child.Ierrgv = private_glob(aTHX_ "@", 1);
	child.Ireplgv = private_glob(aTHX_ "\022", 1);
	GV *root[] = {aTHX->Idefgv, aTHX->Ierrgv, aTHX->Ireplgv};
	GV *owned[] = {child.Idefgv, child.Ierrgv, child.Ireplgv};
	for (unsigned i = 0; i < 3; i++) {
		CHECK(root[i]);
		CHECK(!S_wump_private_scalar(aTHX_ NULL, root[i]));
		Perl_wump_task_activate(aTHX_ &main_task);
		SV **expected = &GvGP(root[i])->gp_sv;
		CHECK(S_wump_private_scalar(aTHX_ &main_task, root[i]) == expected);
		CHECK(Perl_wump_gv_sv(root[i]) == expected);
		Perl_wump_task_activate(aTHX_ &child);
		expected = &GvGP(owned[i])->gp_sv;
		CHECK(S_wump_private_scalar(aTHX_ &child, root[i]) == expected);
		CHECK(S_wump_private_scalar(aTHX_ &child, owned[i]) == expected);
		CHECK(Perl_wump_gv_sv(root[i]) == expected);
		CHECK(Perl_wump_gv_sv(owned[i]) == expected);
	}
	Perl_wump_task_activate(aTHX_ &main_task);
	GV *ordinary = private_glob(aTHX_ "ordinary", 8);
	CHECK(!S_wump_private_scalar(aTHX_ &main_task, ordinary));
	/* Effective-glob identity can change independently of the scalar slot.
	 * Even an otherwise canonical GV must defer aliases to the full path. */
	GV *old_effective = GvEGV(root[0]);
	GvEGV(root[0]) = ordinary;
	CHECK(!S_wump_private_scalar(aTHX_ &main_task, root[0]));
	CHECK(Perl_wump_gv_sv(root[0]) == &GvGP(root[0])->gp_sv);
	GvEGV(root[0]) = old_effective;
	OP op = {0};
	op.op_type = OP_GVSV;
	OP *saved_op = PL_op; PL_op = &op;
	for (unsigned i = 0; i < 3; i++) {
		ENTER; SAVETMPS;
		SV *localized = Perl_wump_localize(aTHX_ root[i], 's');
		CHECK(main_task.locals);
		CHECK(!S_wump_private_scalar(aTHX_ &main_task, root[i]));
		CHECK(*Perl_wump_gv_sv(root[i]) == localized);
		FREETMPS; LEAVE;
		CHECK(!main_task.locals);
		CHECK(S_wump_private_scalar(aTHX_ &main_task, root[i]) == &GvGP(root[i])->gp_sv);
	}
	PL_op = saved_op;
	Perl_wump_task_activate(aTHX_ NULL);
	SvREFCNT_dec(ordinary);
	for (unsigned i = 0; i < 3; i++) SvREFCNT_dec(owned[i]);
}

int main(int argc, char **argv, char **env) {
	CHECK(argc == 2);
	PERL_SYS_INIT3(&argc, &argv, &env);
	PerlInterpreter *interp = perl_alloc(); CHECK(interp);
	PERL_SET_CONTEXT(interp); perl_construct(interp);
	dTHXa(interp);
	char program[] = "scalar-lookup", modules[] = "-Iperl/lib", option[] = "-e";
	char code[] =
		"use v5.42; use Wump; $^R = 0; $_ = 0;"
		"sub hooked { $_ }"
		"sub compute ($id) { $_ = $id; my $sum = $id; $sum += $_ % 97 for 1..2000;"
		" die 'scalar hook lost its act' unless hooked() == $id; return $sum }"
		"my $out = chan(32);"
		"for my $id (1..32) { act { $out->send([$id, compute($id)]) } }"
		"die 'main computation failed' unless compute(100) == 95050;"
		"my %seen; for (1..32) { my $got = $out->recv;"
		" die 'child computation failed' unless $got->[1] == 94950 + $got->[0] && !$seen{$got->[0]}++; }"
		"die 'missing computation' unless keys(%seen) == 32;";
	char *embedding[] = {program, modules, argv[1], option, code, NULL};
	CHECK(perl_parse(interp, NULL, 5, embedding, NULL) == 0);
	CV *hooked = get_cv("main::hooked", 0);
	CHECK(hooked && install_hook(CvROOT(hooked)));
	check_slots(aTHX);
	CHECK(perl_run(interp) == 0);
	CHECK(__atomic_load_n(&hook_calls, __ATOMIC_RELAXED) == 33);
	CHECK(!__atomic_load_n(&public_loads, __ATOMIC_RELAXED)
		&& "canonical active scalar loads must bypass the public accessor");
	PL_perl_destruct_level = 2;
	CHECK(perl_destruct(interp) == 0); perl_free(interp);
	PERL_SYS_TERM();
	puts("ok - canonical scalar cells preserve root/child identity, aliases and scoped localization");
	puts("ok - main and spawned numeric loops bypass general scalar lookup and verify every result");
	puts("ok - replaced scalar opcode entries retain their hooks and act context");
	return 0;
}
