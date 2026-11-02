# Benchmark reference

Commands run from the repository root. The [current matrix](../bench/operation-matrix-current.md),
[raw observations](../bench/operation-matrix-current.json),
[default regression check](../bench/operation-matrix-check.txt) and
[provenance record](../bench/operation-matrix-machine.json) describe the latest
measured source. Superseded captures and checkpoint narratives live in Git.

## Three optimization lanes

Keep implementation commits and measurements separate where practical:

| Lane | Scope | Evidence |
| --- | --- | --- |
| General Perl | Interpreter improvements useful independently of Wump | Matched stock Perl versus Perl with only that change, plus compatibility tests |
| Wump | Scheduler, task and channel improvements | Before/after Wump captures with unchanged fixtures and controls |
| Perl for Wump | Interpreter changes making isolation, suspension or parallel execution cheaper | Before/after Wump benefit and Wump-unused cost, measured separately |

Wump-unused is still the modified interpreter. Improving that column alone
does not establish an upstream Perl improvement. Identify combined changes
without attributing their entire gain to one mechanism. Preserve ordinary
Perl semantics and report failed checks alongside successful ones.

## Common operation matrix

```sh
make bench-matrix STOCK_PERL=/absolute/path/to/stock/perl
make bench-matrix-report
make bench-matrix-check MATRIX_BASELINE=/path/to/compatible/earlier-capture.json
make bench-matrix-test STOCK_PERL=/absolute/path/to/stock/perl
```

The columns compare sequential stock Perl, stock forks and ithreads with
one/two/four workers, Wump unused or on one/two/four execution slots, and Go
on one/two/four slots. Active Wump uses public Perl syntax. The standalone C
runtime has separate probes. Go 1.21 or later is required; Go builds locally
with networking and telemetry disabled.

| Operation | Timed work and unit |
| --- | --- |
| arithmetic | Sum `(iteration + job) % 97`; one iteration |
| calls | Call a one-argument increment function and accumulate; one call |
| arrays | Construct four-element arrays and retain a 32-entry ring; one array |
| hashes | Update/read a private three-key hash/map; one update sequence |
| strings | Format an ASCII number, concatenate and take a prefix; one string |
| regex | Anchored ASCII match, two captures and numeric conversion; one match |
| utf8 | Encode lambda plus an ASCII letter and sum bytes; one encoding |
| json | Encode a two-field JSON object; one encoding |
| yield | Voluntary scheduler yield; one yield |
| spawn | Spawn and receive a unique completion ID in cohorts of at most 1,024; one task |
| channel | Unbuffered request/reply with completion handshake; one round trip |

Common operations run the same independent seeded jobs. Stock and unused
Wump run them sequentially; Wump/Go use tasks. Fork/ithread jobs are assigned
round-robin to at most the requested worker count on stock Perl, without a
persistent pool between samples. Work includes creation, cloning, IPC/result
collection and reaping/joining. Dependencies are loaded before work timing.
These are batch-throughput controls, not bare fork/clone latency or prefork
server measurements. Coroutine rows use the loop count directly and are N/A
for stock, forks, ithreads and Wump-unused.

Work ns/op is elapsed wall time divided by all completed operations. Multiple
slots therefore measure aggregate throughput, not one operation's latency.
Process timing includes startup, dependency loading and report serialization;
work timing excludes those steps. Both workers prepare their common
dependencies before timing, including dependencies used by other rows.

Perl uses native AV/HV/string/regex operations and Encode/JSON::PP; Go uses
slices/maps/strings, regexp and encoding/json. Their allocations and instruction
mixes differ. The Go call function has inlining disabled, and the array ring
retains live values. These fixtures are bounded operation comparisons, not
general language or application speed claims.

Each sample verifies job IDs/counts/checksums against an independent reference.
JSON checks its final payload; channel checks every reply; spawn checks unique
IDs. Known unsupported paths retain diagnostics and N/A cells. Other errors,
warnings, malformed results, timeouts or checksum failures fail the capture.
Unsupported work is never a zero-cost result. Losing previous support fails
the comparison; newly working cells require future timing baselines.

## Capture and comparison

Defaults are five rotated runs, 50,000 iterations and eight jobs. Override
`MATRIX_RUNS`, `MATRIX_ITERATIONS` and `MATRIX_JOBS` deliberately. Every raw
observation and execution sequence is retained. Binaries, build configuration,
source revision, fixture fingerprint, CPU/kernel and inherited affinity are
recorded and checked again before publishing. Failed/incomplete captures
preserve the previous output atomically. Preserve their stderr separately.

```sh
taskset -c 0,2,4,6 make bench-matrix STOCK_PERL=/absolute/path/to/stock/perl
perl bench/matrix-report.pl build/operation-matrix-current.json --metric process
perl bench/matrix.pl /path/to/wump/perl /path/to/stock/perl /path/to/matrix-go \
	--output build/operation-matrix-current.json --runs 5 --iterations 50000 --jobs 8
```

Build the Go executable from `bench/matrix-worker.go` (`make build/matrix-go`).
Each worker has a 90-second timeout. Sanitizer/coverage builds and custom Go
optimization overrides cannot pass a performance gate. Perl startup and Go
runtime tuning overrides are cleared; the locale is C. Build and test before
measuring on an otherwise quiet machine.

The default control is [operation-matrix-baseline.json](../bench/operation-matrix-baseline.json).
It is the existing callee baseline under a stable name, with identical bytes.
The default budget permits at most +10% in each supported Wump cell's median
work and process time. Go has no fixed acceptance ratio. The checker
recomputes medians, rejects missing/duplicate/forged evidence and incompatible
controls, and never hides a slow cell in an aggregate score. Times are absolute;
inspect stock/Go controls when host noise is suspected.

Comparisons require at least three runs, clean captured source, the same
fixtures, work sizes, modes, CPU/kernel/affinity, stock/Go binary hashes and
build settings. Wump's source and binary may change with matching configuration.
Captures are machine-specific. Use a reviewed local baseline on another host;
a toolchain, fixture or placement change requires an explicit new baseline.
No failing command automatically replaces one. Report generation can display
dirty or one-run diagnostics, but those cannot pass a regression gate.

Current captures use schema v3 with fourteen variants. Active samples record
compiled native operation/method bindings; losing a previous binding fails.
Older schema readers remain tested, but cross-schema comparisons are rejected.
Do not fabricate historical observations for changed fixtures.

### Current result

Source `eecbbcd` has 770 observations, including 650 successful samples, at
five runs / 50,000 iterations / eight jobs / affinity `0,2,4,6`. JSON work is
48.95/44.10/42.33 microseconds on one/two/four slots, about 9%/18%/21% lower
than the preceding XS build. Private binding lookup avoids unnecessary
shared-root scans and disposable GP allocation; serial localization also
avoids redundant validation and metadata guards. A separate correctness fix
retains hash keys without changing a shared scalar's TEMP flag.

The default retained-anchor check passes: one-slot JSON is +8.14% work and
+8.12% process. Newly supported two/four-slot JSON cells have no timing baseline
in that anchor. The preceding XS comparison passes every supported metric.
The older pre-XS selection comparison still fails one-slot JSON at +10.64%
work / +10.61% process. Its exact report is retained in the provenance record;
this cleanup does not clear that regression or replace either active baseline.
JSON scaling is weak; hashes, UTF-8, spawn and channels also expose substantial
remaining overhead. Broader ordinary-Perl parity and deployment remain open.

Retrieve superseded captures from Git when investigating a regression:

```sh
git show 91a18ab:bench/operation-matrix-xs-current.json > build/previous-xs.json
perl bench/matrix-check.pl build/previous-xs.json bench/operation-matrix-current.json
```

## Focused probes

```sh
make perl-baseline-test
make perl-perf-test STOCK_PERL=/absolute/path/to/stock/perl
make bench
make bench-compare ITERATIONS=1000000
```

The integer probe uses [perl-baseline.jsonl](../bench/perl-baseline.jsonl),
formerly `perl-scalar-after.jsonl`, with unchanged contents. Its checker
compares work/process time relative to the matched stock control. It measures
one interpreter workload and cannot establish general Perl parity. For direct
use: `perl bench/perl-baseline.pl PRIVATE_PERL STOCK_PERL --runs 5 --iterations 500000 --jobs 8`.

C/Go probes cover spawn, yield, channels, selection, sleeps, socketpair echo,
blocking pipe handoff and compute at one/four workers. Spawn uses bounded
cohorts, not a million simultaneously live tasks. Runtime setup is excluded;
channel operations are round trips. Sleep, echo and blocking use scaled loop
counts. Different syscall-handoff policies limit conclusions about call cost.
`bench/api-overhead.pl`, `bench/channel-overhead.pl`, `bench/perl-parallel.pl`,
`bench/mojo-jobs.pl` and `bench/mojo-cpu.pl` provide focused diagnostics;
[Mojo instructions](../examples/mojo/README.md) describe the bounded application.
Run matching before/after controls instead of treating one probe as a full gate.

## Stock control

Use unmodified Perl 5.42.2 from the same verified archive, matching compiler,
optimization, multiplicity, ithreads and integer width. Default build options:

```sh
bash perl/source.sh build/stock "$PWD/build/perl/perl-5.42.2.tar.xz"
(
	cd build/stock/perl/perl-5.42.2 || exit 1
	sh Configure -des -Dusemultiplicity -Duseithreads -Duse64bitall \
		-Dprefix="$PWD/../install" -Dman1dir=none -Dman3dir=none || exit 1
	make -j4
)
```

`make bench-matrix-test` covers workload results and failure/atomicity paths;
`make bench-matrix-check-test` exercises the checker alone. Its tests also run
in `perl-test`. Keep raw samples, exact comparisons and build provenance with
the current report; remove superseded generated reports from the working tree.
