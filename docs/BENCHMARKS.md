# Benchmark reference

Commands run from the repository root.

## Common operation matrix

The primary matrix compares sequential stock Perl, stock Perl forks and
ithreads with one/two/four workers, the unused Wump fork, Wump with one,
two and four execution slots, and Go with one, two and four execution slots.
The Wump columns execute the Perl API, including scalar message handling.
The standalone C runtime has separate focused benchmarks below.

```sh
make bench-matrix STOCK_PERL=/absolute/path/to/stock/perl
make bench-matrix-report
make bench-matrix-check MATRIX_BASELINE=/path/to/compatible/earlier-capture.json
make bench-matrix-test STOCK_PERL=/absolute/path/to/stock/perl
```

Go builds locally with networking and telemetry disabled. `bench-matrix` builds
the private interpreter, runs the matrix and writes
`build/operation-matrix-current.json` plus a Markdown report. The stock control
must be an unmodified Perl 5.42.2 with matching compiler, optimization,
multiplicity, ithreads and integer-width options. Build instructions for that
control are under the focused benchmarks below.

| Operation | Timed work and unit |
| --- | --- |
| arithmetic | Sum `(iteration + job) % 97`; one iteration |
| calls | Call a one-argument increment function and accumulate; one call |
| arrays | Construct four-element arrays and retain a 32-entry ring; one array |
| hashes | Update/read a private three-key hash/map; one update sequence |
| strings | Format an ASCII number, concatenate and take a prefix; one string |
| regex | Match an anchored ASCII pattern, extract two captures and convert the number; one match |
| utf8 | Encode lambda plus an ASCII letter to UTF-8 and sum its bytes; one encoding |
| json | Encode a two-field JSON object; one encoding |
| yield | Voluntary scheduler yield; one yield |
| spawn | Spawn and receive a unique completion ID, in cohorts of at most 1,024; one task |
| channel | Unbuffered request/reply with a completion handshake; one round trip |

Common operations run the same number of independent seeded jobs. Stock and
the unused Wump fork execute jobs sequentially; Wump/Go execute them as tasks.
Fork/ithread workers run on the unmodified stock interpreter. Jobs are assigned
round-robin to at most the requested worker count, with no persistent pool
between samples. Forks return results through pipes; ithreads return results
through join. Work time includes worker creation, cloning, IPC/result collection
and reaping/joining. Dependencies are loaded before work timing. These columns
measure whole batches, not bare fork/clone call latency, shared-heap tasks or a
prefork server. Each job
has the same loop count. Coroutine primitives use the loop count directly,
independent of the common-job setting. Every job ID/count/checksum is verified
against an independent 97-value reference; JSON's final payload and every
channel reply are also checked. Spawn checks ID uniqueness as well as its sum.

Work ns/op is elapsed wall time divided by the total completed operations
across all jobs. Multi-slot columns therefore describe aggregate throughput,
not the latency of one operation on one core.

The fixtures compare bounded observable work, not identical instruction mixes
or allocation counts. Perl uses native AV/HV/string/regex operations and
`Encode`/`JSON::PP`; Go uses slices/maps/strings, `regexp` and `encoding/json`.
The Go call fixture disables inlining for that function. Array retention keeps
constructed values live across iterations. Go's UTF-8 representation and
Perl's character representation naturally differ. These are operation-level
reference points, not general language or application speed claims.

Stock Perl, forks, ithreads and the unused Wump fork have no equivalent
coroutine fixture, so their primitive cells are explicitly N/A. Process/thread
creation and IPC benchmarks need their own bounded fixtures; the coroutine
spawn row is not a measurement of `fork()` or `threads->create()`.
The JSON worker probes the real entry: the current
multi-slot `utf8::encode` rejection is recorded with its diagnostic. Other
errors, timeouts, warnings, malformed results or incorrect checksums fail the
entire capture. Newly supported JSON is accepted as measured work; losing
previously working support fails the progress comparison. Unsupported work is
never counted as a fast measurement or silently dropped.

`MATRIX_RUNS` defaults to five, `MATRIX_ITERATIONS` to 50,000 and `MATRIX_JOBS`
to eight. Variants rotate between repetitions; execution sequence numbers and
all raw observations are retained. Work timing excludes interpreter startup,
module setup and final report serialization. IPC/result transfer inside a
fork/ithread batch remains timed. Whole-process time includes all setup and
is recorded separately:

Both workers prepare their common dependencies before timing, including those
used by other rows. Whole-process numbers describe these workers, not an empty
Perl or Go program. The work report also shows ratios to stock and Go; these
ratios have no fixed Go acceptance cutoff.

```sh
perl bench/matrix-report.pl build/operation-matrix-current.json --metric process
```

For direct use with existing verified binaries:

```sh
perl bench/matrix.pl /path/to/wump/perl /path/to/stock/perl /path/to/matrix-go \
	--output build/operation-matrix-current.json --runs 5 --iterations 50000 --jobs 8
```

The Go executable must be built from `bench/matrix-worker.go`; it is not the
older C-runtime comparison driver. `make build/matrix-go` builds it. Every
worker has a 90-second timeout. Captures record binary SHA256 hashes, Perl and
Go build settings, CPU model, kernel, inherited CPU affinity, source revision
and a fingerprint of the benchmark sources. Sanitizer/coverage flags and custom
Go optimization flags are rejected. Perl startup and Go runtime tuning overrides
are cleared; the locale is fixed to C.
Workers and binaries are checked again before publication to catch changes
during a run. Source state describes the benchmark checkout; external binaries
are identified by their hashes/configurations, not assumed to come from HEAD.
The normal Make target rebuilds Wump before measuring it.

Run correctness checks and builds first, then collect timings on an otherwise
quiet machine. Use `taskset` around the capture if placement needs to be fixed;
the inherited mask is recorded and must match future captures. Small work sizes
are useful for correctness tests but can be dominated by startup/scheduling
noise. Keep production captures large enough for the measured operation.

### Baselines and regression checks

```sh
make bench-matrix-check MATRIX_BASELINE=bench/operation-matrix-fork-threads-baseline.json \
	MATRIX_CURRENT=build/operation-matrix-current.json MATRIX_MAX_REGRESSION=10
```

The default budget permits a 10% increase in each Wump cell's median work or
whole-process time. Go is an informational reference, with no required speed
ratio. A slow cell cannot be hidden in an aggregate score. The checker
recomputes medians from raw verified samples and rejects missing cells, samples,
duplicate identities, unknown unsupported cases and incompatible captures.
Absolute before/after Wump times are gated; this does not normalize away host
slowdowns, so inspect the stock/Go controls when a result looks noisy.

Comparisons require at least three runs, clean benchmark source, identical
work sizes/modes, CPU/kernel/affinity, benchmark fingerprints, stock/Go control
binaries and build settings. Wump's binary hash and source revision may change;
its build configuration must still match. Report generation accepts dirty or
one-run captures as explicit diagnostics; those cannot pass the historical
regression gate.

The committed baseline is machine-specific. On another machine, first capture
and review a local baseline, then pass its path as `MATRIX_BASELINE`. Updating
toolchains, fixtures or CPU placement requires a deliberate new baseline.
Neither the checker nor a failing run replaces a baseline automatically.
Capture publication is atomic: a failed/incomplete run preserves the previous
JSON file and emits no successful report. Keep failed-run stderr for diagnosis.
Review every cell before accepting a new baseline, including N/A entries and
small or noisy regressions.

The readable initial results live in
[operation-matrix-baseline.md](../bench/operation-matrix-baseline.md); the
[raw capture](../bench/operation-matrix-baseline.json) retains its evidence.
Tooling checks run with `make bench-matrix-test`; its unit checks also run in
`perl-test`. They include regression boundaries, missing/forged results,
support loss, mismatched builds/affinity and atomic failed captures.

The initial clean capture uses five runs, 50,000 iterations, eight jobs and
affinity `0,2,4,6` on the recorded Ryzen 7 PRO 4750U. Its 88 cells retain 400
timed samples and 40 explicit N/A samples. Reproducing that particular record
requires the same prepared stock/Go controls and affinity; ordinary unpinned
captures intentionally cannot pass a comparison with it. A baseline self-check
validates the record, not an improvement over an earlier matrix.

New captures use schema v2 with fourteen variants. Archived v1 captures remain
readable and comparable with other compatible v1 captures. A v1/v2 comparison
is rejected: adding process/thread controls requires a fresh baseline, never
fabricated historical samples. Tooling tests cover uneven worker partitions,
more slots than jobs, failed worker creation, child failure and reaping/joining
all workers before propagating failure.

The [expanded baseline](../bench/operation-matrix-fork-threads-baseline.md) and
[raw capture](../bench/operation-matrix-fork-threads-baseline.json) retain five
runs at 50,000 iterations/eight jobs with affinity `0,2,4,6`. Its 154 cells
contain 640 timed and 130 explicit N/A samples. The
[before capture](../bench/operation-matrix-fork-threads-before.json) uses the
same fixtures and controls with the preceding runtime binary. The
[comparison](../bench/operation-matrix-stack-cache-check.txt) passes the 10%
gate: bounded cold-stack reuse reduces Perl spawn/completion time by
12.69%/6.21%/8.08% on one/two/four slots. Four-slot compatibility yield increases
9.995%, close to the budget; this checkpoint does not establish its stability
under other placements. Fork and ithread columns describe independent batches,
not the shared-heap semantics or memory use of Wump acts.

### Perl API wrapper probe

```sh
WUMPPROCS=1 build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	-Iperl/lib bench/api-overhead.pl yield public 200000
WUMPPROCS=1 build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	-Iperl/lib bench/api-overhead.pl yield xs 200000
WUMPPROCS=1 build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	-Iperl/lib bench/api-overhead.pl yield native 200000
```

`bench/api-overhead.pl` compares the public Perl wrapper with the same internal
XS entry for yield or spawn. Yield also has a native opcode mode, using the
same Perl loop with no wrapper or XS dispatch. Spawn retains the same channel
methods in both modes, isolating only `act`'s wrapper. All verify the completed count. Rotate
paired runs on the same binary and CPU mask. Internal entries are diagnostic,
not a supported application API. Removing this wrapper still leaves an XS
call, interpreter bookkeeping and the runtime operation. Native-mode timings
measure the implemented keyword directly. The common matrix's `yield` row
currently measures qualified `Wump::yield()` through the compatibility path;
the focused probe distinguishes that from the native operation.
Ordinary compute-row overhead cannot
be attributed to Wump API wrappers, which those timed loops never invoke.

## Existing focused benchmarks

### Matched integer benchmark

`make perl-baseline-bench` compares matching stock and private Perl 5.42.2
builds, then Wump with one, two and four slots. It checks compiler flags,
optimization, architecture and interpreter configuration, rejects sanitizer
builds and verifies every job against a closed-form integer reference. The
plain fork run measures overhead even when `use Wump` is absent; the one-slot
Wump run additionally includes act/channel scheduling. Raw JSON samples include
work/process timing, CPU time, build configuration, CPU model and source state.
Captures also record the inherited CPU affinity mask. The comparison gate
rejects differing recorded masks and reports when legacy evidence has no mask.
An unrestricted mask still lets the OS place workers on SMT siblings; fixed
physical-core controls must be compared separately from unrestricted runs.
Five interleaved runs rotate execution order; summaries report medians and
ratios without imposing a performance threshold.

Compatibility work also has a separate performance regression check:

```sh
# Run after correctness checks finish, with the machine otherwise quiet:
make perl-perf-test STOCK_PERL="$PWD/build/stock/perl/perl-5.42.2/perl"
# Or compare two existing complete captures:
make perl-perf-check PERL_PERF_BASELINE=before.jsonl PERL_PERF_CURRENT=after.jsonl
make perl-perf-check-test
```

To examine scaling beyond the standard one/two/four-slot gate, add eight slots:

```sh
perl bench/perl-baseline.pl "$PWD/build/perl/perl-5.42.2/perl" \
  "$PWD/build/stock/perl/perl-5.42.2/perl" --max-slots 8 --runs 7
```

This retains stock, ordinary-fork and all standard slot controls. Extended
captures require the same mode set on both sides of a regression comparison;
the checker rejects missing or contradictory advertised eight-slot evidence.

The check defaults to a maximum 10% increase in stock-normalized median work
or whole-process time for ordinary Perl and Wump on one/two/four slots.
It recomputes medians from verified raw samples and requires complete captures
with at least three runs, clean source revisions, matching workloads, CPU
models and uninstrumented compiler configurations. Whole-process time includes
loading and result verification as well as work. Failed captures remain in
`$(BUILD)/perl-baseline-current.jsonl.tmp`; successful captures are preserved
before comparison, including when the regression budget fails.

`PERL_PERF_BASELINE` defaults to the recorded canonical-scalar checkpoint. Use a baseline
captured on your own machine when its CPU model or configuration differs.
`PERL_PERF_MAX_REGRESSION` selects an explicit percentage budget. This prevents
backsliding from a checkpoint; it does not satisfy the outstanding active-Wump
overhead or scaling goals. One integer fixture does not cover general Perl
performance, so compatibility investigations also retain representative
upstream-case timings and the Unicode application benchmark.

The [compatibility checkpoint](../DESIGN.md#compatibility-and-performance-gates-2026-10-30)
records the complete standard noninteractive upstream pass, publication fix,
and fresh performance comparisons. Its large upstream XS macro case measured
about 2.12x stock with Wump disabled. The newer
[core integration assessment](../DESIGN.md#core-scalar-access-and-ordinary-perl-acceptance-2026-10-31)
rechecks that case and a broader ordinary-workload matrix. Most measured paths
still take roughly 1.7–3.5x stock work time; the fast integer loop does not
establish ordinary-Perl parity. These regressions block upstream acceptance.

The latest [scalar-lookup checkpoint](../DESIGN.md#canonical-scalar-lookup-and-affinity-controls-2026-10-31)
cuts one/two/four-slot integer work another 12–13%, to 4.25x/2.20x/1.21x stock
time. Standard and application comparisons pass the 10% budget. With one
hardware thread per physical core, eight-slot seven-run medians use 32–34% less
work time and 24–32% less whole-process time than sequential stock at two work
sizes. Unrestricted short eight-slot timing still exceeds the prior checkpoint
by 18% in stock-relative work time and fails its optional regression gate;
placement sensitivity remains open. Both affinity policies and every raw
capture are retained. These results cover one parallel fixture; broad parity
and single-slot overhead remain open.

The [original matched-stock run](../bench/perl-stock-baseline.jsonl) exposed large
overheads on the implicit-loop-variable integer workload. A fresh
[before](../bench/perl-ordinary-before.jsonl)/[after](../bench/perl-ordinary-after.jsonl)
comparison reduces ordinary fork time from 8.17x stock to 0.92x stock, by
bypassing inactive context selection and inlining native opcode bodies.
The next [active-runtime comparison](../bench/perl-active-after.jsonl) cuts one-slot
work time from 3.187s to 1.622s, reducing slowdown from 25.17x to 12.79x stock.
Two/four slots improve by 3.12x/2.84x but remain slower than one slot.
The [active integration checkpoint](../DESIGN.md#active-arithmetic-and-live-mojo-checkpoint-2026-10-30)
records the new native audits, race fixes, four-slot HTTP acceptance and
remaining performance gates.
The [design assessment](../DESIGN.md#ordinary-execution-checkpoint-2026-10-30)
records the configuration, validation, profiles and remaining goals. This one
ordinary loop does not establish general stock-Perl parity; active-Wump
overhead, near-linear scaling and the 2x runtime target remain unmet.

Build the stock control from the same verified source archive without applying
the Wump patches. These Configure options match the default private build:

```sh
bash perl/source.sh build/stock "$PWD/build/perl/perl-5.42.2.tar.xz"
(
	cd build/stock/perl/perl-5.42.2 || exit 1
	sh Configure -des -Dusemultiplicity -Duseithreads -Duse64bitall \
		-Dprefix="$PWD/../install" -Dman1dir=none -Dman3dir=none || exit 1
	make -j4
)
make perl-baseline-test
make perl-baseline-bench
```

`STOCK_PERL` selects another matching stock executable. For larger or repeated
samples, invoke `perl bench/perl-baseline.pl PRIVATE_PERL STOCK_PERL --runs 5
--iterations 500000 --jobs 8`. This integer workload measures interpreter and
runtime overhead; it does not establish general application performance or
the Unicode dashboard's scaling. See the [design assessment](../DESIGN.md#implementation-assessment-updated-2026-10-31)
for the remaining acceptance goals.

### C runtime primitives

```sh
make bench
make bench-compare
make bench-compare ITERATIONS=1000000
```

CSV output reports spawn/completion, voluntary yield, unbuffered round trips,
a buffered 4-producer/4-consumer channel, ready two-channel selection,
one-microsecond sleeps, socketpair echo, blocking pipe handoff, and four
compute tasks at 1 and 4
workers. Both implementations check message counts/checksums and use the
same work sizes and buffer capacities. Spawn uses batches of at most 1024
tasks, so it does not measure a million simultaneously live tasks. The
small stack cache intentionally makes this workload expose mapping churn.
Each CPU operation is one xorshift iteration; ping-pong operations are
whole round trips. Setup of the runtime itself is excluded from timings.
The sleep case runs ceil(ITERATIONS / 100) sleeps; each reported operation
is one sleep, including scheduler and OS wakeup latency.
Echo runs ceil(ITERATIONS / 10) round trips of an eight-byte sequence value
over a nonblocking Unix socketpair. Both implementations verify replies;
Go uses pollable `os.File` handles. Connection/poller setup is excluded.
The `blocking` case runs ceil(ITERATIONS / 1000) native blocking pipe reads,
with channel requests and a yielding writer. C uses explicit handoff and
Go uses raw `syscall.Read`; the timing includes the native calls and
scheduling, including C's first replacement setup. The runtimes use
different handoff policies, so these figures are not a general comparison
of syscall cost.

The Go comparison builds locally with networking and telemetry disabled,
and keeps its build cache under `build/`. Treat measurements as local
baselines, not stable performance claims; repeat on an idle machine before
drawing conclusions.

The [scheduler checkpoint](../DESIGN.md#owned-local-scheduling-and-pending-work-polling-2026-10-31)
removes clock queries for empty global queues and unnecessary one-slot queue
coordination. Five-run local medians reduce C yield from 1,219 to 62 ns on one
slot; actual Perl yield falls from 1.78 to 0.53 µs and channel round trips from
10.80 to 7.79 µs. The full records include unchanged/slower workloads. Spawn
still takes 6.7x/16.8x Go on one/four slots, and echo also exceeds the 2x goal.
These are primitive measurements; general Perl compatibility, ordinary stock
parity and static deployment remain unfinished.

[baseline.csv](../bench/baseline.csv) records a 100,000-iteration run on
2026-10-23 with GCC 14.2.1 and Go 1.26.5 (`GOEXPERIMENT=nodwarf5`,
Linux amd64). It shows compute scaling while exposing substantial remaining
spawn overhead. [select-timers.csv](../bench/select-timers.csv) records the
expanded suite on 2026-10-24 with the same toolchain, including selection
and sleep. [netpoller.csv](../bench/netpoller.csv) adds the Unix socketpair echo
baseline; it does not measure TCP networking.
[syscall-handoff.csv](../bench/syscall-handoff.csv) adds the blocking pipe case
on 2026-10-25 with the same toolchain. The machine reports 16 online CPUs;
these figures do not establish behavior on other hardware or long-running
workloads.
