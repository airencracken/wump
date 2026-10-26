/* Included in core regcomp.c, where native engine-private layouts are known.
 * Match pregfree2/regfree_internal's owned SV edges; never invoke an engine. */
#ifndef PERL_IN_XSUB_RE
void Perl_wump_regex_roots(pTHX_ REGEXP *rx,
	void (*visit)(pTHX_ SV *, void *), void *arg) {
	regexp *r = ReANY(rx);
	if (!r) return;
	visit(aTHX_ (SV *)r->mother_re, arg);
	visit(aTHX_ (SV *)r->qr_anoncv, arg);
	visit(aTHX_ (SV *)r->paren_names, arg);
	if (r->substrs) {
		for (int i = 0; i < 2; i++) {
			visit(aTHX_ r->substrs->data[i].substr, arg);
			visit(aTHX_ r->substrs->data[i].utf8_substr, arg);
		}
	}
#ifdef PERL_ANY_COW
	visit(aTHX_ r->saved_copy, arg);
#endif
	/* A lightweight copy borrows its private storage from its mother.
	 * A custom engine's pprivate is deliberately opaque to this helper. */
	if (r->mother_re || r->engine != &PL_core_reg_engine || !r->pprivate) return;
	regexp_internal *ri = RXi_GET(r);
	if (ri->code_blocks) {
		for (int i = 0; i < ri->code_blocks->count; i++)
			visit(aTHX_ (SV *)ri->code_blocks->cb[i].src_regex, arg);
	}
	if (!ri->data) return;
	for (U32 i = 0; i < ri->data->count; i++) {
		switch (ri->data->what[i]) {
		case 'a': case 'r': case 's': case 'S': case 'u':
			visit(aTHX_ (SV *)ri->data->data[i], arg);
			break;
		default:
			/* OP pointers and engine tables are not SVs. */
			break;
		}
	}
}
#endif
