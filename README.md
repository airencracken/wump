# wump

Stackful coroutines and parallel execution for Perl 5, inspired by Go's tasks
and channels. Wump combines a standalone C runtime with an experimental Perl
5.42.2 fork on Linux x86-64. Acts share one interpreter and compiled code,
with separate execution state for supported paths.

The project is a parallel preview. General Perl/XS compatibility, ordinary
stock-Perl performance and standalone deployment remain unfinished.

## Current status

| Area | Working today | Remaining work |
| --- | --- | --- |
| Tasks | Stackful C tasks; Perl closures on multiple slots; channels, wait groups, yielding and compute checkpoints | Native core language surface and broader execution-context coverage |
| Perl state | Audited stacks, pads, exceptions, captures, localization and shared-value paths | Remaining interpreter globals, magic, weak references and XS/compiler boundaries |
| I/O | C epoll sockets/pipes and explicit blocking-call handoff; a tested Mojolicious fixture | General Perl I/O integration and transparent native-call handling |
| Performance | Verified comparisons against stock Perl, forks, ithreads and Go, with saved regression baselines | Lower ordinary-Perl and task overhead, cheaper spawn, larger-scale validation |
| Deployment | A private interpreter build | Static application bundles, dependency tooling and portability |

See the [design and implementation assessment](DESIGN.md#implementation-assessment-updated-2026-10-31)
for the goals and current evidence. The [audit](docs/EXECUTION-CONTEXT-AUDIT.md)
and [invariants](docs/INVARIANTS.md) define supported boundaries; passing selected
tests does not establish general CPAN compatibility or thread safety.

## Build and run

The C runtime requires GCC or Clang with C11 support, GNU Make, pthreads and
GNU `timeout`:

```sh
make
make test
./build/hello
```

Build the private Perl fork separately. Source acquisition verifies the pinned
release archive; this does not replace system Perl.

```sh
make perl-fetch
make perl-build
make perl-test
WUMPPROCS=4 build/perl/perl-5.42.2/perl \
	-Ibuild/perl/perl-5.42.2/lib -Iperl/lib examples/tasks.pl
```

Use `PERL_TARBALL=/path/to/perl-5.42.2.tar.xz` with `make perl-build` when the
archive is already available. `PERL_JOBS=4` controls compilation. Run Perl
build/test targets serially against a generated tree.

## Perl tasks

```perl
use v5.42;
use Wump;

my $results = chan(4);
for my $number (1..4) {
	act { $results->send($number * $number) };
}
say scalar $results->recv for 1..4;
```

`use Wump` runs top-level Perl as the main act. `WUMPPROCS` selects execution
slots and defaults to one. `act` spawns a closure; channels copy scalars and
preserve reference identity. Main return ends the runtime, so applications
must receive results or explicitly wait for registered work. An uncaught act
exception stops the process; `eval` catches exceptions within an act.

Bare `yield` compiles to a native core opcode in `use Wump` scope. Other
task/channel operations still use functions. The design's full core syntax,
Perl `sel` and deployment tool are pending. See the
[Perl integration reference](docs/PERL-INTEGRATION.md) for APIs, examples,
localization, memory rules and explicit restrictions.

The optional [Mojolicious dashboard](examples/mojo/README.md) exercises bounded
jobs, HTTP/WebSocket progress and shutdown on one/four slots.

## Performance matrix

The matrix requires Go 1.21 or later. Go is a reference point. Progress is
measured against previous Wump captures, without requiring a fixed Go speed
ratio. The matrix covers ordinary operations
and coroutine primitives, retaining unsupported cells and every raw sample.

```sh
make bench-matrix STOCK_PERL=/absolute/path/to/stock/perl
make bench-matrix-check \
	MATRIX_BASELINE=/path/to/compatible/earlier-capture.json
```

The default columns are sequential stock Perl, stock Perl forks and ithreads
on one/two/four workers, Wump unused or on one/two/four slots, and Go on
one/two/four slots. Work and whole-process timing stay separate.
Coroutine-only fixtures are N/A for stock Perl, forks and ithreads. The checker
flags regressions
against the saved baseline; it never turns unsupported work into a fast result.
The [recorded matrix](bench/operation-matrix-fork-threads-baseline.md) includes
the fork and ithread controls;
use a local baseline when your machine, CPU mask or controls differ.

Read the [benchmark guide](docs/BENCHMARKS.md) for workload definitions, baseline
updates, machine/build requirements and the existing focused benchmarks.

## Development references

- [C runtime and lifetime rules](docs/RUNTIME.md), [public header](runtime/include/wump.h)
- [Perl APIs and implementation details](docs/PERL-INTEGRATION.md)
- [Tests, sanitizers and known tooling failures](docs/VALIDATION.md)
- [Benchmark matrix and historical measurements](docs/BENCHMARKS.md)
- [Execution and memory invariants](docs/INVARIANTS.md), [state inventory](docs/state-inventory.tsv)
- [Architecture and milestones](DESIGN.md)

Build products stay under `build/`. Keep fork changes in the tracked patch
sources under `perl/`; `make clean` removes generated source trees and binaries.
