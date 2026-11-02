# Validation reference

Commands run from the repository root. The [compatibility reference](COMPATIBILITY.md),
[invariants](INVARIANTS.md) and [state catalogue](state-inventory.tsv) distinguish
tested behavior from unfinished audits. Selected tests do not establish
general Perl/XS thread safety or CPAN compatibility.

## Current verification

Measured source is `193914b`: empty-queue reclamation probes, package-scalar
lock identity selection and live cancellation test synchronization. The
production core matches `904f1d9`; the final source adds only the live-test
fixture. Subsequent report updates change documentation and generated evidence.

| Check | Result and scope |
| --- | --- |
| Normal project | Complete `perl-test` passes, including native C/C++/embedding, source upgrade/idempotence, inventory and opcode checks |
| AddressSanitizer | Complete project passes with full teardown and stack-use-after-return; leak detection is separate |
| Whole-core TSan, scoped | Package lock 4, retirement 8, memory 54, hash keys 8, local lookup 8, JSON 18, UTF-8 16, caller 12, element marks 4, GVs 4 and parallel 56 assertions pass |
| Native TSan controls | Idle/destructor collection probe, C/C++ borrows, eight-executor reclamation, retirement fault/clone and allocator fixtures pass; the deliberate `Perl_more_bodies` race is detected |
| LeakSanitizer, scoped | Package lock, retirement, memory and JSON suites plus native ownership, C/C++ borrows, eight-executor reclamation and fault fixtures pass with full teardown |
| Stock differentials | Context 53 and legacy 26 assertions pass against matched unmodified Perl 5.42.2 |
| Full upstream | 2,919 files / 1,351,358 checks pass in UTC, with upstream skips and expectations unchanged |
| Parser regeneration | Bison 3.8.2 regeneration matches |
| Mojolicious integration | 50 live HTTP/WebSocket assertions pass on each of one/four slots with prepared 9.37 dependencies and the controlled cancellation analyzer |
| Runtime archive integrity | All six runtime objects match the members linked into each normal/ASan/TSan Perl archive; copied core sources match the measured revision |

No whole-upstream sanitizer or complete TSan project pass is claimed. The
separate full-TSan ithreads failure described below remains open.

The preceding frozen interpreter fails the idle-collection zero-mutex probe.
It also fails all four package-lock assertions: a parked writer makes GV
lookup reject a lock operand before lock acquisition. The fix waits to inspect
plain published heads, then releases its reader before acquiring the user
lock. Alias contention preserves every increment; ordinary reads and explicit
publication still reject foreign mutation. Retirement tests preserve borrowed
storage, exact destruction, destructor-enqueued records and quiescent cleanup.

The original finite-work live probe failed one four-slot shutdown cancellation
assertion. The original run did not record the final job state; diagnostic repeats
passed on both interpreters. Those passes alone do not establish the cause. The revised test requires admission and running state,
then keeps doing real Unicode analysis until cancellation through the existing
analyzer injection point. The demo's production code is unchanged. A cancelled
control exits, while an uncancelled control cannot complete and times out.
Final live tests pass on current one/four slots and the frozen four-slot control.
The original failure and all diagnostic runs remain in local logs.

The [default matrix check](../bench/operation-matrix-check.txt) passes.
See the [benchmark guide](BENCHMARKS.md#current-result) for all comparisons and
budget margins. [Provenance](../bench/operation-matrix-machine.json) retains
raw-capture identities, exact reports, runners and source/binary/archive/log
hashes. Local logs/builds are under `build/checkpoint-reclamation/`. The active
baselines and legacy checker fixture bytes are unchanged.

## Normal and stock compatibility checks

```sh
make test
make perl-test
make perl-state-inventory-test
make perl-context-compat-test STOCK_PERL=/absolute/path/to/stock/perl
make perl-legacy-compat-test STOCK_PERL=/absolute/path/to/stock/perl
TZ=UTC make perl-upstream-full-test
make perl-parser-test
make bench-matrix-test STOCK_PERL=/absolute/path/to/stock/perl
```

The complete upstream target runs its noninteractive core, bundled-library
and extension harness, retaining upstream platform/optional/interactive skips.
It clears inherited Perl library options and packaging skips. Defaults are
four test processes and a 30-minute timeout; configure `PERL_FULL_TEST_JOBS`
and `PERL_FULL_TEST_TIMEOUT`. Use UTC to avoid host DST timestamp ambiguity.
The same ZIP timestamp case has reproduced on stock Perl during the local
clock overlap. Never change assertions or add skips to conceal a failure.

Context checks compare user call frames, arguments, contexts, block eval,
localization, captures and destruction in inactive/cooperative/parallel modes.
The actor wrapper is a deliberate extra call boundary. Legacy checks compare
names/prototypes, hints, warning policy/hooks, output handles/separators and
read-only C-locale queries in inactive modes, including `require Wump` without
import. They do not prove parallel locale or shared-handle safety.

Native lookup tests wrap the public accessor and pthread mutex entry to check
correct private values without native mutex calls. Localization regressions
exercise alias precedence, pockets, callbacks, exception restoration and GP
replacement/lifetime. Tests of overloaded hash keys check yielding conversion,
failed conversion, exact destruction and subsequent successful assignment.

## Runtime checks

`make test` covers context/errno/FP preservation, stack guards, actual parallel
work, queue overflow and reuse, channel FIFO/model checks, close/free ordering,
exact-once delivery, shutdown, deadlock detection and independent runtimes.
Delivery varies workers and capacities. Selection covers duplicates, disabled
cases, randomized readiness, lock ordering, timeout/message/cancel races and
abandonment. I/O covers pipes, socketpairs, loopback TCP, descriptor reuse,
timeout/close races, EOF/half-close and ownership. `make stress` repeats the
behavior suites ten times, including higher-worker timeout races.

Fault fixtures inject allocation, mutex/condition/thread, stack, timer,
poller and descriptor failures. They check rollback, cleanup, unchanged
outputs, callback suppression and later recovery. Native handoff tests verify
replacement execution, migration, errno/FP/stack state, timer/I/O progress and
shutdown. Preemption checks use more compute tasks than slots and retain
watchdogs for starvation.

Run focused runtime cases with `./build/test_runtime --case 'channel free'`,
`./build/test_select --case 'channel-timeout'` or
`./build/test_io --case 'external pipe'`. Focused passes do not clear other
failed integration cases. TCP/half-close tests require local socket permission;
an environment denial remains a reported failure.

## Sanitizers

```sh
make sanitizers
make perl-asan
make perl-lsan
make perl-tsan
make perl-ubsan
make perl-msan
```

Runtime targets include GCC/Clang ASan/LSan, UBSan, TSan, MSan and Clang CFI.
`make perl-sanitizers` runs separate whole-project Perl variants. Sanitizer
controls must detect deliberately invalid programs; real-suite diagnostics
are never suppressed. ASan uses fiber hooks and retains stack-use-after-return
checks across migration/handoff. TSan uses fiber and channel-lock ownership
hooks. MSan tracks origins. CFI uses LTO/hidden visibility/LLD. Pointer-pair
controls need address,pointer-compare,pointer-subtract instrumentation.
Instrumented watchdogs are larger without removing assertions.

Use separate `BUILD` directories. `PERL_SANITIZER` alone does not instrument
the runtime: pass matching runtime compile/link flags when building manually.
For example, the ASan project run uses:

```sh
ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1 \
PERL_DESTRUCT_LEVEL=2 make perl-test BUILD=build/check-asan \
	PERL_SANITIZER=address \
	CFLAGS='-std=c11 -O1 -g -Wall -Wextra -Werror -pthread -fsanitize=address -fno-omit-frame-pointer' \
	LDFLAGS='-pthread -lm -fsanitize=address'
```

Use `thread`/`-fsanitize=thread` for TSan and retain its fiber hooks. Inspect
archive members after cached builds; `perl/deps.mk` makes miniperl/libperl
depend on runtime objects. Supply `PERL_TARBALL` to reuse the verified archive.
Leak tests use `detect_leaks=1`, full teardown and a deliberate leak control.
LSan needs tracer permission; failure to inspect threads remains a failure.
Hardware tagging, shadow/unsafe-stack modes and additional sanitizer families
need their own platform/ABI integration and are not claimed here.

## Known failures and limits

The full TSan project target finds an upstream ithreads clone race on
`PL_veto_switch_non_tTHX_context` in `tests/perl/keys.t`. It remains enabled;
passing the scoped Wump suites does not clear it. Whole-Perl MSan currently
stops in `S_querylocale_2008_i`, with an origin in uninstrumented glibc
`__newlocale`, before project suites run. Instrumented dependencies are needed.

`make memcheck` checks a separate runtime build with registered coroutine
stacks. `make valgrind` also covers Perl suites/native fixtures and profiling;
focused targets include `perl-valgrind`, `perl-mojo-valgrind`,
`valgrind-tools` and `perl-valgrind-tools`. Configure `VALGRIND_ITERATIONS`,
`VALGRIND_SLOTS` and `VALGRIND_TIMEOUT`; preserve report directories/status
manifests. Intentional guard faults alone disable reporting inside the child
that must die. Real invalid accesses and definite/indirect leaks fail.

Installed Valgrind 3.27.1 aborts internally in Helgrind during pthread join
(reproduced without Wump) and DRD at exit. These remain tool failures; other
profiling results cannot establish their race-safety claims. Runtime
compilation/Test2 and unaudited XS restrictions remain explicit in
[compatibility](COMPATIBILITY.md); no compiler gate was relaxed for this sweep.
