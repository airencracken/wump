sub apply_poll {
	my ($source) = @_;
	my $file = 'dist/IO/IO.xs';
	my $module = "MODULE = IO\tPACKAGE = IO::Seekable\tPREFIX = f";
	my $mode_helpers = <<'C';
#ifdef PerlIO
#include "perliol.h"
#endif

static bool
wump_io_magic_only(SV *value)
{
    if (SvTYPE(value) < SVt_PVMG) return !SvMAGICAL(value);
    for (MAGIC *magic = SvMAGIC(value); magic; magic = magic->mg_moremagic)
        if (!Perl_wump_publish_magic(magic) && magic->mg_type != PERL_MAGIC_backref)
            return FALSE;
    return TRUE;
}

static int
wump_io_nonblocking(pTHX_ SV *handle, int mode)
{
#if defined(PerlIO) && defined(HAS_FCNTL)
    struct wump_mutation *guard = Perl_wump_metadata_begin(aTHX);
    struct wump_borrow *capture = Perl_wump_capture_begin(aTHX_ handle);
    if (!wump_io_magic_only(handle))
        croak("Wump: parallel handle mode requires a plain native handle");
    SV *glob = SvROK(handle) ? SvRV(handle) : handle;
    (void)sv_2mortal(newRV_inc(glob));
    Perl_wump_capture_end(aTHX_ capture);
    capture = Perl_wump_capture_begin(aTHX_ glob);
    if (SvTYPE(glob) != SVt_PVGV || !wump_io_magic_only(glob) || !isGV_with_GP(glob))
        croak("Wump: parallel handle mode requires a plain native handle");
    IO *io = GvIO((GV *)glob);
    if (io) (void)sv_2mortal(newRV_inc((SV *)io));
    Perl_wump_capture_end(aTHX_ capture);
    capture = io ? Perl_wump_capture_begin(aTHX_ (SV *)io) : NULL;
    if (io && !wump_io_magic_only((SV *)io))
        croak("Wump: parallel handle mode requires a plain native handle");
    InputStream stream = io ? IoIFP(io) : NULL;
    /* Reject layers whose fileno implementation can enter Perl. The
     * owned reactor handles use only these native Unix buffering layers. */
    for (PerlIO *layer = stream; PerlIOValid(layer); layer = PerlIONext(layer)) {
        const char *name = PerlIOBase(layer)->tab->name;
        if (!name || (strNE(name, "unix") && strNE(name, "perlio")))
            croak("Wump: parallel handle mode requires native Unix layers");
    }
    int result = io_blocking(aTHX_ stream, mode);
    int error = errno;
    Perl_wump_capture_end(aTHX_ capture);
    Perl_wump_mutation_end(aTHX_ guard);
    errno = error;
    return result;
#else
    PERL_UNUSED_ARG(handle);
    PERL_UNUSED_ARG(mode);
    croak("Wump: parallel native handle mode is unavailable");
    return -1;
#endif
}

C
	my $io_text = read_file("$source/$file");
	my $module_at = index($io_text, $module);
	$module_at >= 0 or die "missing IO preamble boundary\n";
	my $helper_at = index($io_text, "#ifdef PerlIO\n#include \"perliol.h\"\n#endif\n\nstatic bool\nwump_io_magic_only(");
	$helper_at = $module_at if $helper_at < 0;
	substr($io_text, $helper_at, $module_at - $helper_at, $mode_helpers);
	write_file("$source/$file", $io_text);
	edit($file, '#include "poll.h"', <<'C');
#include "poll.h"
#include <limits.h>

static SV *
wump_poll_argument(pTHX_ SV *value)
{
    SV *copy = Perl_wump_xs_scalar(aTHX_ value, "parallel poll");
    if (!SvOK(copy)) croak("Wump: parallel poll requires integer arguments");
    STRLEN length;
    const char *text = SvPV(copy, length);
    UV number;
    int flags = grok_number(text, length, &number);
    if (!(flags & IS_NUMBER_IN_UV) || (flags & ~(IS_NUMBER_IN_UV | IS_NUMBER_NEG))
        || number > (UV)INT_MAX + ((flags & IS_NUMBER_NEG) ? 1 : 0))
        croak("Wump: parallel poll requires integer arguments in native int range");
    IV integer = flags & IS_NUMBER_NEG ? -(IV)number : (IV)number;
    sv_setiv(copy, integer);
    return copy;
}
C
	edit($file, "_poll(timeout,...)\n\tint timeout;", "_poll(timeout,...)\n\tSV *timeout;");
	my $text = read_file("$source/$file");
	my $start = index($text, "\n_poll(timeout,...)\n");
	my $end = index($text, "\nMODULE =", $start);
	$start >= 0 && $end >= 0 or die "missing poll entry\n";
	my $entry = substr($text, $start, $end - $start);
	unless (index($entry, '/* Wump zero-time poll admission. */') >= 0) {
		my $prepare = <<'XS';
PPCODE:
{
    /* Wump zero-time poll admission. */
    int wump_timeout;
    SV **wump_originals = NULL;
    struct wump_mutation **wump_guards = NULL;
    if (Perl_wump_parallel(aTHX)) {
        SV *copy = wump_poll_argument(aTHX_ timeout);
        if (SvIVX(copy) != 0)
            croak("Wump: parallel poll requires zero timeout");
        if ((items - 1) % 2)
            croak("Wump: parallel poll requires descriptor/event pairs");
        wump_timeout = 0;
        if (items > 1) {
            SSCHECK(6);
            Newx(wump_originals, items - 1, SV *);
            SAVEFREEPV((char *)wump_originals);
            Newxz(wump_guards, items - 1, struct wump_mutation *);
            SAVEFREEPV((char *)wump_guards);
            for (I32 arg = 1; arg < items; arg++) {
                wump_originals[arg - 1] = ST(arg);
                wump_guards[arg - 1] = Perl_wump_mutation_begin(aTHX_ ST(arg));
                copy = wump_poll_argument(aTHX_ ST(arg));
                if (SvREADONLY(ST(arg))) croak_no_modify();
                ST(arg) = copy;
            }
        }
    } else wump_timeout = (int)SvIV(timeout);
XS
		$entry =~ s/^PPCODE:\n\{\n/$prepare/m or die "missing poll code\n";
		$entry =~ s/    if\(\(ret = poll\(fds,nfd,timeout\)\) >= 0\) \{/    ret = poll(fds,nfd,wump_timeout);\n    if (wump_originals)\n        for (i = 1; i < items; i++) ST(i) = wump_originals[i - 1];\n    if (ret >= 0) {/
			or die "missing native poll call\n";
		$entry =~ s/    XSRETURN_IV\(ret\);/    if (wump_guards)\n        for (I32 arg = items - 2; arg >= 0; arg--)\n            Perl_wump_mutation_end(aTHX_ wump_guards[arg]);\n    XSRETURN_IV(ret);/
			or die "missing poll return\n";
	}
	substr($text, $start, $end - $start, $entry);
	write_file("$source/$file", $text);
	edit($file, "io_blocking(handle,blk=-1)\n\tInputStream\thandle\n\tint\t\tblk",
		"io_blocking(handle,blk=&PL_sv_undef)\n\tSV *handle\n\tSV *blk");
	edit($file, "    const int ret = io_blocking(aTHX_ handle, items == 1 ? -1 : blk ? 1 : 0);", <<'XS');
    int ret;
    if (Perl_wump_parallel(aTHX)) {
        int mode = -1;
        if (items > 1) {
            SV *copy = wump_poll_argument(aTHX_ blk);
            if (SvIVX(copy) != 0)
                croak("Wump: parallel handle mode only supports queries or nonblocking");
            mode = 0;
        }
        ret = wump_io_nonblocking(aTHX_ handle, mode);
    } else {
        InputStream stream = IoIFP(sv_2io(handle));
        ret = io_blocking(aTHX_ stream, items == 1 ? -1 : SvIV(blk) ? 1 : 0);
    }
XS
	my $registration = <<'XS';
#ifdef HAS_POLL
    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv("IO::Poll::_poll", 0));
#endif
#ifdef HAS_FCNTL
    if (!PL_wump_task) Perl_wump_xs_allow(aTHX_ get_cv("IO::Handle::blocking", 0));
#endif
XS
	$text = read_file("$source/$file");
	$text =~ s{^#ifdef HAS_(?:POLL|FCNTL)\n    if \(!PL_wump_task\) Perl_wump_xs_allow\(aTHX_ get_cv\("(?:IO::Poll::_poll|IO::Handle::blocking)", 0\)\);\n#endif\n}{}mg;
	$text =~ s/(\nBOOT:\n\{\n)/$1$registration/ or die "missing IO bootstrap\n";
	write_file("$source/$file", $text);
}
1;
