# Validation reference

Commands run from the repository root.

## Verification

The [execution-context audit](EXECUTION-CONTEXT-AUDIT.md) distinguishes
tested behavior, explicit compatibility restrictions and unresolved risks.
[INVARIANTS.md](INVARIANTS.md) and the complete
[state catalogue](state-inventory.tsv) describe the ownership and lifetime
assumptions future changes must preserve. Selected tests do not establish
general thread safety or CPAN compatibility.

```sh
make perl-state-inventory-test
make perl-context-compat-test STOCK_PERL=/absolute/path/to/stock/perl
make perl-legacy-compat-test STOCK_PERL=/absolute/path/to/stock/perl
```

The stock control must be unmodified Perl 5.42.2. The differential checks
unused, one-actor, cooperative and multi-slot modes separately, and retains
known unsupported native-entry behavior explicitly. The inventory check also
runs as part of `perl-test`.

The legacy differential checks ordinary names/prototypes, lexical hints and
warning policy, nested warning/exception hooks, selected output handles and
separators, and read-only C-locale queries. It compares stock, the unused fork,
and the fork after `require Wump` without import, each with `WUMPPROCS=1`, `4`,
and an invalid unused value. It preserves exact observations and diagnostics;
this unused-mode evidence does not establish parallel locale or shared-handle
safety. Both differential targets require an explicit stock control and remain
separate from `perl-test`.

`make perl-upstream-full-test` runs upstream's complete noninteractive core,
bundled-library and extension harness against the private fork. It clears
inherited library options and packaging skips, uses four test processes and a
30-minute overall timeout by default. `PERL_FULL_TEST_JOBS` and
`PERL_FULL_TEST_TIMEOUT` configure those limits. Upstream's platform, optional
dependency and interactive-test skips remain visible in the log. This ordinary
Perl compatibility check complements the project's explicit Wump/parallel
suites; it does not exercise every library with Wump enabled.

### Native primitive checkpoint (2026-11-01)

Native yield/act/channel/sleep checks pass normally (30 + 44 + 84 checks).
The preceding interpreter fails 11 of the new constructor/timer suite's native
compilation, bypass and mask assertions, demonstrating the added paths.
The complete project suite, context/legacy stock differentials, source upgrade
and idempotence, parser/opcode regeneration and state-inventory checks pass.
The current matrix tooling passes 119 unit and 400 integration checks, including
all three API paths for four operations on one/four slots and cohort boundaries.
The full ordinary upstream harness passes 2,919 files / 1,351,255 checks with
`TZ=UTC` and no new exclusions or changed expectations.

The first local-time upstream run failed IO::Compress's ZIP timestamp round-trip
test 46 during the host's November 1 daylight-saving overlap. The unchanged
test reproduces the same failure on matched stock Perl; both stock and Wump
pass its 230 checks under `TZ=UTC`. Set the environment explicitly when
reproducing this checkpoint:

```sh
TZ=UTC make perl-test perl-context-compat-test perl-legacy-compat-test \
	perl-upstream-full-test bench-matrix-test perl-parser-test \
	STOCK_PERL=/absolute/path/to/stock/perl
```

A separate instrumented private Perl passes the complete project suite with
`ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1` and
`PERL_DESTRUCT_LEVEL=2`; all focused native checks also pass. This does not
include a whole-upstream sanitizer, leak-checking or new TSan run. Standalone
ASan fake-stack/migration and five deliberate-error controls pass with
`-fsanitize=address,pointer-compare,pointer-subtract` and invalid-pointer-pair
detection enabled. An address-only control invocation first failed the pointer
comparison control; rebuilding with its required instrumentation resolved the
configuration error without changing expectations.

The [performance comparison](../bench/operation-matrix-native-check.txt) has
one failing cell: four-slot yield work time (+11.87%). The
[interleaved follow-up](../bench/native-primitives-yield-followup.md) measures
+6.86% with larger work; that does not clear the original failure. The default
baseline retains the preceding interpreter so subsequent checks keep reporting
the regression. Correctness passes and performance status are separate evidence.

`make test` runs isolated, timeout-bounded cases covering argument errors,
stack guards, ABI registers, floating-point state, errno, real four-worker
parallelism, queue overflow, stack reuse, FIFO ordering, randomized buffer
operations against a reference model, closing blocked tasks, channel-free
publication, exact-once message delivery, shutdown cleanup, deadlocks, and
independent runtimes. Message delivery runs with 1/2/4/8/16 workers and
capacities 0/1/7/256. The selection suite covers duplicate channels,
disabled/default cases, randomized ready choices, selected closed-channel
operations, selection-to-selection rendezvous with opposite lock orders,
timer expiry and cancellation, timeout/message races, unchanged losing
outputs, and abandoned selections. The I/O suite covers external pipe
wakeups while workers are idle, simultaneous read/write waits, parallel
socketpair echo, timeout/close races, descriptor reuse, EOF/half-close,
loopback TCP, runtime ownership, and leak-free shutdown. `make stress`
repeats all four behavior suites ten
times, including timeout races at 1/4/16 workers.

Checkpoint tests put more computing tasks than execution slots into busy loops
at 1/2/4 workers, checking progress, errno preservation, and shutdown before a
time budget begins. The Perl preemption suite checks tight loops in main and
spawned acts, timer progress, retained task state, and deferred switching in
destructors, with alarm-bounded subprocesses that expose starvation failures.

The failure suite injects allocation, mutex/condition initialization,
stack mapping/protection, and partial thread-start failures. It checks
that started threads are joined, stack mappings are released, the main
task never runs on failed startup, and subsequent runs/spawns still work.
It also injects monotonic condition-attribute failures, selection allocation
failures, and timer allocation/growth failures after parking, checking that
outputs and existing waits stay intact and later operations still work.
The I/O failure suite injects poller/thread/descriptor setup failures,
epoll rearm/wait errors, timer allocation errors, interrupted reads and
writes, accepted-descriptor registration failure, stale connect readiness,
and close EINTR. It checks fd counts and rollback, preserves libc's
fortified entry points in the fault harness, and deliberately delays an
old epoll event until after descriptor/slot reuse to test generation checks.
These syscall fixtures complement the real network integration tests.

The handoff suite checks one-slot pipe progress, callback stack/thread
identity, timer/I/O progress during a native call, overlapping native calls,
bounded normal execution after exit, errno/FP/stack preservation, unbalanced
markers, shutdown, and independent runtimes. Its fault suite checks atomic
replacement-setup failure, callback suppression, deadlock detection after
failed enter, thread/condition cleanup, idle thread reuse, and rejection of
new handoffs once shutdown has published its stop flag. Startup failure
coverage includes partially constructed machine lists.

`make ubsan` fails immediately on undefined behavior. `make tsan` uses the
[ThreadSanitizer fiber API](https://github.com/llvm/llvm-project/blob/main/compiler-rt/include/sanitizer/tsan_interface.h)
and transfers the logical channel-lock ownership when parking switches
from task to scheduler on the same OS thread. The target also requires a
separate, deliberately racy program to produce a TSan report; sanitizer
failures in the real suite are never suppressed. The intentional guard
fault restores SIGSEGV's default disposition in its isolated child.
`make asan` uses the
[AddressSanitizer fiber API](https://github.com/llvm/llvm-project/blob/main/compiler-rt/include/sanitizer/common_interface_defs.h)
to preserve each coroutine's fake stack across migration and native-call
handoff. Completed and abandoned tasks retire those stacks, and recycled
stack mappings have their shadow state cleared. Stack-use-after-return
detection stays enabled. Positive controls verify private fake stacks;
negative controls must detect deliberate heap-use-after-free, stack overflow,
and use-after-return on coroutine stacks.

`make lsan` runs the ASan runtime suites with leak detection enabled and
requires a deliberate leaked allocation to produce a LeakSanitizer report.
Leak checks are separate from `make asan`, which sets `detect_leaks=0`.
Linux LSan needs tracer access to stop and inspect threads. Restricted
environments can fail even on a clean program with a fatal LSan/ptrace
diagnostic; the leak targets report that failure without suppressing it.
Both leak targets check a clean process before running leak-sensitive suites.
Local TCP and socket half-close tests also require their system calls to be
permitted by the environment; a denied call remains a test failure.

`make sanitizers` runs separate GCC and Clang builds and continues independent
checks after a failure while preserving the failing overall status. Individual
targets are `gcc-sanitizers`, `clang-sanitizers`, `gcc-ubsan`, `clang-ubsan`,
`asan`, `lsan`, `tsan`, `msan` and `cfi`. `BUILD` keeps their output isolated.
`CLANG`, `CLANG_CXX`, `CLANG_AR` and `MSAN_CC` select the LLVM tools.
Changing the compiler, compile flags or link flags rebuilds cached runtime
objects; an unchanged configuration reuses them.

Instrumented C runs allow 120 seconds per forked test case and 300 seconds
per suite. Pointer-pair instrumentation exceeded the original case/suite
budgets in a measured CPU-bound run. These explicit watchdog budgets retain
every assertion; ordinary tests retain their existing time limits.

| Check | Runtime tooling |
| --- | --- |
| Address and leak errors | GCC/Clang ASan, stack-use-after-return, unrelated pointer comparisons/subtractions, and leak controls |
| Undefined behavior | GCC/Clang UBSan; GCC strict bounds; Clang local bounds, implicit conversions and nullability; explicit floating division checks |
| Data races | GCC/Clang TSan with fiber and channel-lock ownership support and a deliberate race control |
| Uninitialized reads | Clang MSan with level-2 origins; heap, coroutine stack/native handoff and channel-transfer controls |
| Indirect call types | Clang CFI with LTO, hidden visibility, LLD and a deliberately incompatible callback control |

UBSan controls require overflow, bounds and floating division reports;
the expanded Clang target also checks implicit conversion detection. CFI and
MSan first require a clean coroutine process. An unsupported compiler, missing
runtime, crash, timeout or missing expected diagnostic fails its target.
The shell tooling tests also exercise rejected reports, paths with spaces,
argument preservation and continued execution after individual tool failures.

This matrix covers the current C/x86-64 runtime. Hardware tagging and shadow
call-stack modes require additional platform/ABI work; SafeStack requires
separate support for coroutine unsafe stacks and migration. C++ vptr checks
do not apply to the C runtime. DataFlowSanitizer, TypeSanitizer and
RealtimeSanitizer need separate integration and workload contracts; they are
not claimed by these targets. Defined unsigned arithmetic in the scheduler's
randomization is not treated as an undefined-behavior failure.

`make perl-asan` builds a separate private interpreter and runtime under
`build/perl-asan/`, instruments compiled XS fixtures, and runs the project
suites with full Perl teardown. `make perl-lsan` repeats those suites with
leak detection enabled. A normal build directory cannot be silently reused
as an ASan build or vice versa. Both targets accept `PERL_TARBALL` for the
pinned archive already on disk. TSan remains a separate build.

`make perl-sanitizers` runs the complete project Perl checks in separate ASan,
LSan, TSan, UBSan and MSan builds. They can also be selected as `perl-tsan`,
`perl-ubsan` or `perl-msan` alongside the existing ASan/LSan targets. MSan
selects Clang for the core and Clang++ for native C++ fixtures; fixture drivers
honor `CXX`. `make perl-refcount-clang` checks the C/C++ counter helpers and
compare/exchange behavior against the normal interpreter. C counters use C11
atomics, avoiding GCC-only acceptance of compiler builtins on `_Atomic` fields.

The full TSan run currently finds an upstream `threads.pm` race on
`PL_veto_switch_non_tTHX_context` in the cloned-interpreter regression in
`tests/perl/keys.t`. The test remains enabled and fails the target; passing
Wump parallel-execution suites do not clear that separate compatibility gate.

Whole-Perl MSan requires compatible instrumentation of its dependencies, as
described in the [MSan documentation](https://clang.llvm.org/docs/MemorySanitizer.html).
On the current host, its build stops in `S_querylocale_2008_i`, with an origin
inside glibc `__newlocale`, before the Perl suites can run. This report is not
suppressed. A suitable instrumented dependency/toolchain setup is still needed
to validate whole-Perl MSan; the C runtime MSan suite passes independently.

`make memcheck` builds a separate variant with
[Valgrind stack registrations](https://valgrind.org/docs/manual/manual-core-adv.html)
and checks the behavior and failure suites for invalid accesses and
definite/indirect leaks. Logs go to `build/valgrind/`. Only the intentional
guard-page write disables Memcheck error reporting, in the child that must
still terminate with SIGSEGV; ordinary tests retain full error reporting.

`make valgrind` adds every `PERL_SUITES` test, the C/C++ native fixtures,
embedded interpreter checks, optional Mojo memory checks, and profiling of
both the C runtime benchmark and the Perl Unicode job pipeline. It uses a
separate `build/perl-valgrind` interpreter. Focused targets are `perl-valgrind`,
`perl-mojo-valgrind`, `valgrind-tools` and `perl-valgrind-tools`.
`valgrind-tools` runs Memcheck, Helgrind, DRD, Massif (including stacks),
Callgrind, Cachegrind (including branches), DHAT, experimental BBV and Lackey.
Each tool also has its own target: `memcheck-tools`, `helgrind`, `drd`, `massif`,
`callgrind`, `cachegrind`, `dhat`, `bbv`, and `lackey`.

`VALGRIND_ITERATIONS` (default 100), `VALGRIND_SLOTS` (default 4) and
`VALGRIND_TIMEOUT` (default 300 seconds per profiling tool) control workload
size. Reports, workload CSV/stdout, tool stderr and `status.tsv` live under
`build/valgrind/reports/run.*` or `build/perl-valgrind/reports/run.*`.
Use `callgrind_annotate`, `cg_annotate`, `ms_print` or the DHAT viewer for
the corresponding files. A tool failure never prevents subsequent profiling
tools from running, and the combined command still fails.

The installed Valgrind 3.27.1 aborts internally in Helgrind during pthread join
(also reproducible without Wump) and in DRD at process exit after the benchmark.
Those runs remain failures, with reports preserved. The other profiling tools
complete; these results do not establish Helgrind/DRD race safety.

Run a focused case with `./build/test_runtime --case 'channel free'`.
Selection cases support the same filter, for example
`./build/test_select --case 'channel-timeout'`.
I/O cases support it too: `./build/test_io --case 'external pipe'`.

The full I/O suite requires permission for IPv4 loopback sockets and socket
operations such as shutdown. Some command sandboxes return EPERM for those
calls while allowing socketpair/pipe I/O. The full test, stress, and
sanitizer targets intentionally retain those integration checks; they do
not silently skip them. Run on a host with local socket access when the
sandbox denies these operations. Filtered socketpair/pipe checks and syscall
fixtures do not establish that the TCP/half-close checks passed.

## Native channel and context checkpoint (2026-11-01)

Final code `58e749c` passes the normal project suites, execution-context and
legacy differentials, source-upgrade/idempotence checks, state inventory,
C/C++ and embedded-interpreter fixtures, opcode regeneration and Bison 3.8.2
parser regeneration. The unchanged full upstream harness passes in UTC:
**2,919 files / 1,351,420 checks**. Native channel tests have 48 checks; native
yield has 30 and scalar writes 250, including root/child numeric contexts and
multi-slot scalar/list yields. The preceding interpreter fails eight channel
entry/bypass assertions; its observable channel behavior checks pass.

A separate fully instrumented ASan interpreter passes the project suites with
`detect_leaks=0:detect_stack_use_after_return=1` and `PERL_DESTRUCT_LEVEL=2`.
The three focused suites also pass with leak detection enabled and full
teardown. This is not a whole-upstream ASan/LSan claim. The first ASan build
omitted the standard options and stopped on miniperl startup leaks; the
standard build and focused full-teardown runs pass separately.

Whole-core TSan passes `perl-parallel-test`, its deliberate user-race positive
control and the same three focused suites with
`halt_on_error=1:exitcode=66` and full teardown. An earlier parallel run exposed
a pre-existing TEMP-cleared publication race. The ownership regression fails
on the preceding interpreter and passes after publication transfers every
actual temporary-stack owner, including duplicates, into private RV holders.
The repaired job fixture also passes five stress runs of three samples, eight
jobs each (120 jobs). This scoped result does not clear the separate upstream
ithreads failure in the full-project TSan target described above; that complete
target was not rerun here.

The performance tools pass 134 unit and 477 integration checks. The
[final matrix comparison](../bench/operation-matrix-channel-check.txt) passes
the unchanged 10% work/process budget. Earlier failing captures remain in the
[measurement history](../bench/operation-matrix-channel-current.md), alongside
all raw samples and separate interleaved probes. Four matrices (3,080 samples)
and seven focused datasets (420 samples) were revalidated for complete sample
identities, results, source/binary hashes, pairing and exact saved check text.

Build trees and detailed logs remain locally under
`build/checkpoint-native-channel/`; final normal, sanitizer and tooling logs
are copied to its `validation-logs/` directory. The tracked benchmark records
retain source revisions, binary hashes, configurations and exact capture
runners; generated binaries and raw profiler memory are not committed.
