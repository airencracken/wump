# Wump + Mojolicious job dashboard

One process, one interpreter, four Wump worker coroutines, real HTTP and
WebSocket progress. Workers analyze Unicode log text using bounded channels;
their CPU loops contain no explicit yields. The dashboard and `/health` stay
available while work runs through Wump's preemption points.

The Perl bridge currently has **one execution slot**. This demo establishes a
correctness and responsiveness baseline; it does not demonstrate parallel Perl
or multi-core speedup. The standalone C runtime's multi-executor support is a
separate capability.

## Run

Build the private Perl as described in the repository README. Install the
optional pure-Perl Mojolicious dependency in a local module directory visible
through `PERL5LIB`. `cpanfile` pins the tested version, 9.37; for example, with
cpanminus available:

```sh
cpanm --local-lib-contained "$PWD/build/mojo-deps" Mojolicious@9.37
export PERL5LIB="$PWD/build/mojo-deps/lib/perl5${PERL5LIB:+:$PERL5LIB}"
make perl-mojo-example
```

Open <http://127.0.0.1:3000>. The launcher accepts `--listen`, `--workers`,
`--max-active`, and `--max-history`:

```sh
build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	examples/mojo/dashboard.pl --listen http://127.0.0.1:3000 --workers 4
```

Ctrl-C or SIGTERM stops acceptance, cancels queued/running jobs, drains the
result queue, and joins the dispatcher, workers, and collector. Startup and
shutdown each print one JSON record to stdout. Logs go to stderr.

## API and limits

| Route | Behavior |
| --- | --- |
| `POST /jobs` | JSON `{ "text": "INFO hello", "passes": 40 }`; returns 202 and `Location` |
| `GET /jobs/:id` | Job state, progress, elapsed time, counts, and top 20 words |
| `DELETE /jobs/:id` | Request cooperative cancellation; terminal jobs remain unchanged |
| `GET /jobs` | Retained jobs, worker activity, counters, and configured limits |
| `GET /health` | Process ID and execution mode |
| `WS /events` | Latest service snapshot when changed, plus periodic heartbeats |

Defaults: eight active jobs, sixteen retained jobs, 64KiB UTF-8 input per job,
100 analysis passes, 4096 distinct normalized words per job, and chunks of 32
lines. Each pass contributes to the totals. Words use Unicode case folding and
NFC normalization; internal straight/curly apostrophes are preserved. A line's
first uppercase ERROR/WARN/INFO/DEBUG token determines its level, otherwise
OTHER. CRLF and blank lines are supported; one final LF is a terminator.

Admission includes running jobs, so a full service returns 429 immediately
with `Retry-After: 1`. Invalid JSON/input returns 400, excessive input 413,
unknown jobs 404, and submissions after shutdown 503. Failed jobs retain a
bounded error message and the workers continue. History evicts only terminal
jobs. All state is in memory and disappears on restart.

The input queue is bounded by admission; chunk and result queues each hold at
most twice the worker count. A dispatcher absorbs queue waits outside request
callbacks. Cancellation is checked between analysis passes and chunks. Only
the reactor act touches Mojo controllers, sockets, and WebSocket transactions.
Each subscriber queues at most one outgoing snapshot frame at a time and its
timer is removed on disconnect. There is no authentication or persistence;
the launcher binds loopback by default.

## Reactor boundary

`Wump::Mojo::Reactor` derives from `Mojo::Reactor::Poll`, forces each native
poll to return without waiting, then sleeps the act for 2ms. This explicitly
bridges the two schedulers. It adds polling overhead and is not native epoll
integration or general blocking-call handoff. Blocking Perl/XS calls still
occupy the execution slot. The launcher selects this reactor and disables
optional JSON XS, native DNS, SOCKS, and TLS integrations for the baseline.

The demo uses static HTML/JS and JSON routes. EP templates, development reload,
prefork servers, subprocess CPU offload, arbitrary XS, and multiple Perl
execution slots are outside this acceptance test. Dependencies and Unicode
tables load before worker acts start. Process signal handlers only set a flag;
the reactor observes it and performs shutdown in its owning act.

## Acceptance test

```sh
make perl-mojo-test
# Focused core and Mojo memory checks (requires Valgrind):
make perl-mojo-memcheck
# Repeat the external TCP load test with a custom health p95 budget (ms):
perl tests/perl/mojo-live.t "$PWD/build/perl/perl-5.42.2/perl" 500
```

The optional target requires Mojolicious and a stock Perl 5.42+ client. The
ordinary core suite remains independent of Mojolicious. Service tests cover
hand-counted Unicode fixtures, reference equivalence, queue saturation, worker
failure/recovery, cancellation, bounded history, and shutdown. Test::Mojo
checks routes and WebSocket lifecycle. The external client starts the actual
server on an ephemeral loopback port, submits concurrent CPU jobs, compares
results with a stock-Perl sequential implementation, measures health p95,
observes WebSocket progress during work, repeats batches with an RSS growth
budget, cancels through HTTP, sends SIGTERM during work, and rebinds the same
port. It prints a JSON measurement record in TAP diagnostics.

These are local acceptance budgets, not throughput promises. One short RSS
plateau check cannot establish long-term leak freedom. Multi-slot throughput,
native I/O handoff, and longer soak runs remain future acceptance gates.
