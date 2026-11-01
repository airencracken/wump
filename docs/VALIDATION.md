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
