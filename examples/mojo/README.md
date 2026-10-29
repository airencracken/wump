# Wump + Mojolicious job dashboard

One process, one interpreter, four Wump worker coroutines, real HTTP and
WebSocket progress. Workers analyze Unicode log text using bounded channels;
their CPU loops contain no explicit yields. The dashboard and `/health` stay
available while work runs through Wump's preemption points.

The HTTP dashboard remains a **one-slot acceptance baseline**. Its Unicode
job backend can now run on one, two or four execution slots in the same
interpreter and has a separate CPU benchmark below. Running the complete HTTP
stack with multiple slots still needs further XS and runtime compilation work.
Option parsing now finishes in `CHECK`, before execution slots start. The
pinned native cwd readers and plain-scalar path canonicalizers have focused
parallel audits and tests. The current four-slot startup gate is
`File::Spec::Unix::_fn_catfile`; its module-context constants and path joining
still need an audit before live HTTP acceptance can run on four slots.

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
Ready events, health responses and service snapshots report `execution_slots`
from the runtime, separately from the number of worker acts.

## CPU backend benchmark

This benchmark runs the same job service, Unicode analyzer, bounded queues,
scoped locks and collector used by the dashboard. It needs the private Perl
and its bundled Time::HiRes/Unicode::Normalize extensions, but does not need
Mojolicious installed. It measures the CPU pipeline without HTTP, WebSockets,
JSON serialization or reactor polling.

```sh
make perl-build
make perl-mojo-cpu-test
make perl-mojo-cpu-bench
# Save raw samples and summaries as JSON Lines:
perl bench/mojo-cpu.pl "$PWD/build/perl/perl-5.42.2/perl" \
	--runs 3 --jobs 8 --passes 20 --workers 4 > build/mojo-cpu.jsonl
```

The runner keeps the worker count, input and analysis passes identical across
one, two and four slots. Every job must complete and match the whole-input
sequential reference before a sample is accepted. Records include actual slot
count, wall/CPU time, throughput, executable/version and source revision/dirty
state. Summaries report median wall/CPU times and speedup relative to one slot.
The built-in fixture has 128 Unicode log lines; each worker scans every line
for every requested pass. The reference counts once and scales its totals,
so its execution time is excluded rather than used as a performance baseline.

Timing starts after module loading and reference construction, and includes
pool startup, batch admission, worker initialization, dispatch, analysis,
collection and completion polling. Separate process timing includes startup and verification.
The collector, synchronization and metadata costs are part of the measured
pipeline. A larger slot count is not assumed to be faster; the tests impose
correctness checks without a speedup threshold. These results establish a
backend baseline and do not measure Mojolicious request throughput.

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
plateau check cannot establish long-term leak freedom. Multi-slot HTTP
throughput, native I/O handoff, and longer soak runs remain future acceptance
gates. CPU backend measurements use the separate benchmark above.
