# Benchmark reference

Commands run from the repository root.

## Three optimization lanes

Keep implementation commits and measurements separate where practical:

| Lane | Scope | Evidence |
| --- | --- | --- |
| General Perl | Interpreter improvements useful independently of Wump | Matched unmodified Perl versus the same Perl with that change, plus compatibility tests |
| Wump | Scheduler, task, channel and other Wump runtime improvements | Before/after Wump captures with unchanged fixtures and controls |
| Perl for Wump | Interpreter changes that make isolation, suspension or parallel execution cheaper | Before/after Wump benefit and Wump-unused cost, measured separately |

The Wump-unused column is still the modified interpreter. A faster unused
column alone does not establish a general upstream Perl improvement. Changes
that mix lanes should identify each part and its evidence; avoid attributing
a combined gain to a single mechanism. Preserve stock behavior outside the
intentional concurrency semantics and retain every failed regression result.

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
make bench-matrix-check MATRIX_BASELINE=bench/operation-matrix-callee-baseline.json \
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

New captures use schema v3 with fourteen variants and imported public Wump
syntax. Every active sample records the native operations found in the compiled
worker; the checker rejects missing/inconsistent bindings and loss of a previous
binding. This describes the shared worker's compiled branches, not an assertion
that every operation executes in every row. Archived v1/v2 captures remain
readable and comparable within their schema. Cross-schema comparisons are
rejected: changed fixtures require a fresh matched baseline, never fabricated
historical samples. Tooling tests cover uneven worker partitions,
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

### Native syntax checkpoint

The first matched v3 [baseline](../bench/operation-matrix-native-baseline.md)
and [current capture](../bench/operation-matrix-native-current.md) retain the
same five-run parameters, controls and affinity as the expanded v2 record.
Both rerun the public-syntax fixture on clean `bc96e17`: the preceding binary
compiles native yield; the new binary also compiles native act/channel creation.
Each capture retains 154 cells / 770 samples (640 timed, 130 N/A).
The [comparison](../bench/operation-matrix-native-check.txt) reports spawn work
reductions of 1.83%/3.06%/12.73% on one/two/four slots, but **fails** the unchanged
10% gate for four-slot yield (+11.87%). All other work/process cells remain
within budget. That historical capture did not replace its baseline. The
channel checkpoint reruns that same preceding binary with the fixture below.

A separate [interleaved yield follow-up](../bench/native-primitives-yield-followup.md)
uses seven runs of two million operations on both binaries. It measures
+0.11%/+6.86% on one/four slots. Its different fixture/work size does not
invalidate the original failure or establish that it was noise. No scheduler
change or threshold adjustment was made to chase the measurement.

The [four-operation API record](../bench/native-primitives-api.md) retains 168
same-binary samples, compiler/binary/source identities and the exact runner.
Native channel creation/close takes 33.1%/31.9% less work time than its wrapper;
zero sleep takes 72.7%/79.7% less and spawn/completion 3.9%/13.2% less. Removing
XS still leaves substantial task creation and messaging work. These are
separate workloads from the common matrix, with all paths sharing the same
remaining channel methods.

### Native channel and context checkpoint

The [latest matched matrix](../bench/operation-matrix-channel-current.md)
passes the unchanged 10% work/process gate against its
[fixed anchor](../bench/operation-matrix-channel-baseline.md). Channel work
falls 32.81%/29.06%/31.47%, spawn 14.73%/9.04%/15.18% and yield
2.41%/2.26%/2.70% on one/two/four slots. The full comparison includes native
act/constructor work since the anchor as well as channel dispatch, the TEMP
ownership fix and numeric/yield context refinements. All four captures use
five runs, 50,000 iterations, eight jobs and CPU mask `0,2,4,6`, retaining
154 cells / 770 samples each. That checkpoint retains the original native-yield
anchor. The callee checkpoint below uses the completed channel build as its
new before binary.

The [initial check](../bench/operation-matrix-channel-initial-check.txt) fails
three arithmetic work cells and one process cell. The
[numeric-refinement check](../bench/operation-matrix-channel-arithmetic-check.txt)
passes arithmetic but fails two-slot yield work (+17.15%). Both remain saved.
Seven-run interleaved [numeric](../bench/native-channel-arithmetic.md) and
[yield](../bench/native-channel-yield.md) probes retain separate references,
work sizes, ranges and exact runners; none clears a failed full-matrix result.
The final capture passes independently. Scheduling variation and different
binary layouts limit causal claims about small differences.

The [same-binary channel probe](../bench/native-channel-api.md) isolates method
dispatch: native buffered pairs take 31.4%/29.2% less work time than wrappers
on one/four slots; request/reply takes 32.3%/35.4% less. The extra reduction
versus direct XS is 1.6%/1.3% and 4.3%/2.4%, respectively. All paths have the
same inheritance depth and use method lookup. Most of this dispatch gain is
removing Perl wrappers; synchronization, publication and ordinary interpreter
work remain. These measurements do not establish application speed or Go parity.
Three 84-sample API captures and four 42-sample follow-ups retain all 420 raw
samples with clean source revisions, binary/configuration hashes and runners.
The matrix tools' 134 unit and 477 integration checks pass.

### Perl-for-Wump callee checkpoint

This is lane three: adapting the interpreter to lower Wump execution cost.
The ordinary reference/CV call path now takes one protected snapshot rather
than repeated flag snapshots. Separate correctness fixes protect stash class
and name reads during overload-cache initialization. The standalone scheduler
and channel implementation is unchanged; these are not upstream-only Perl
patches or a separate Wump runtime optimization.

The [full matrix](../bench/operation-matrix-callee-current.md) measures calls
13.73%/18.30% faster on two/four slots, with one-slot/unused calls nearly flat
(-0.38%/-0.33%). Its [comparison](../bench/operation-matrix-callee-check.txt)
**fails** two-slot yield work at +21.19%; all other work/process metrics stay
within the unchanged 10% budget. The preceding native-channel/context build,
rerun with matching fixtures/controls, is the default baseline. The candidate
does not replace that anchor. Both captures retain all 770 samples.

The seven-run [call probe](../bench/perl-callee-calls.md) uses 500,000 iterations
and eight jobs, retaining 63 samples including unchanged stock controls.
Calls improve 14.89%/17.77% on two/four slots; one-slot and unused improve
2.62%/2.54%. These larger samples are separate from the 50,000-iteration
matrix. Each iteration includes modulo, increment call and accumulation work;
this is not an isolated lock or ABI cost. An unused-mode improvement does not
establish an upstream Perl benefit. Four slots still take longer than two.

The [yield follow-up](../bench/perl-callee-yield.md) retains another 28 samples
using the exact matrix worker at 50,000/two million yields on two slots. It
measures +4.18%/+2.23%. Generated core/active-dispatch sources and selected
object `.text` sections match, while final relocations/layout may differ.
Neither observation clears the original failure or proves noise; its cause
remains unresolved. The complete 1,540 matrix and 91 focused samples retain
source/binary identities, configurations and exact capture runners. Tooling
passes 134 unit and 477 integration checks. No sample or threshold was changed
to obtain a passing comparison.

### Perl API wrapper probe

`bench/channel-overhead.pl buffered|rendezvous wrapper|xs|native ITERATIONS`
adds a separate channel dispatch probe. All modes use method lookup and the
same ID-backed channel proxies, then select equivalent legacy Perl wrappers,
direct compatibility XS aliases, or the new core method entries. Buffered work
counts send/receive pairs on capacity one; rendezvous work counts request/reply
exchanges between two acts and verifies worker completion. Each reply, total
count and checksum is checked. Constructor setup and final closes are outside
work timing. Native mode verifies all three method bindings before execution,
rejecting an entry rebound to compatibility XS rather than silently labelling
it native. Method identities in matrix v3 are recorded separately from compiled
opcodes; archived records without this optional field remain readable.

```sh
WUMPPROCS=1 build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	-Iperl/lib bench/api-overhead.pl yield public 200000
WUMPPROCS=1 build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	-Iperl/lib bench/api-overhead.pl yield xs 200000
WUMPPROCS=1 build/perl/perl-5.42.2/perl -Ibuild/perl/perl-5.42.2/lib \
	-Iperl/lib bench/api-overhead.pl yield native 200000
```

`bench/api-overhead.pl` compares the public Perl wrapper with the same internal
XS entry and native core operation for yield, spawn, channel creation/close or
zero-duration sleep. All three modes use matching Perl loops; spawn retains the
same channel methods and channel creation retains the same close method.
Native mode verifies the requested operation exists in the compiled optree,
rejecting binaries that would silently fall back to function dispatch.
All verify the completed count. Rotate
paired runs on the same binary and CPU mask. Internal entries are diagnostic,
not a supported application API. Removing this wrapper still leaves an XS
call, interpreter bookkeeping and the runtime operation. Native-mode timings
measure the implemented operation directly. Schema v3 of the common matrix
uses imported public syntax; archived v1/v2 used qualified compatibility calls.
Ordinary compute-row overhead cannot
be attributed to Wump API wrappers, which those timed loops never invoke.

The [recorded native-yield experiment](../bench/native-yield-api.md) retains
seven rotated one/four-slot runs: native yield takes 189.5/641.3 ns versus
598.4/3351.2 ns through the wrapper. Direct XS takes 321.3/1358.4 ns. The raw
samples and machine record retain counts, process times, order, hashes and
the capture runner. The [focused C stack-cache record](../bench/stack-cache-runtime.md)
also retains every measured workload and a larger selection follow-up;
these fixtures have different work from the Perl API matrix.

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
