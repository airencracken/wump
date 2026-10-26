# wump

Go-style parallel concurrency for Perl. The [design](DESIGN.md) describes the
Perl fork and its standalone C runtime. This checkout implements the runtime
and an initial single-slot Perl integration on Linux x86-64.

Implemented:

- Stackful tasks with a SysV assembly context switch, callee-saved registers,
  MXCSR, x87 control word, and task-local `errno` at scheduling boundaries.
- Fixed virtual stacks: 256 KiB for spawned tasks, 1 MiB for the main task,
  a protected guard page below each, and a bounded cache of retired stacks.
- Parallel workers with local FIFO queues, global overflow, half-queue work
  stealing, periodic global-queue polling, and condition-variable sleeping.
- Execution slots separated from OS threads, with explicit blocking-call
  handoff, replacement-thread reuse, and slot reacquisition before a task
  returns to normal runtime code.
- Buffered and unbuffered channels with byte-copy values, FIFO waiters,
  close/drain semantics, and wakeups after the parked task's stack is saved.
- Channel selection with randomized polling, duplicate/disabled cases,
  atomic winner selection, default cases, and monotonic timeouts.
- Cooperative task sleep and a cancellable timer heap that progresses
  while workers have runnable work and while all workers are idle.
- Edge-triggered epoll I/O for sockets and pipes, including timed
  readiness/read/write/accept/connect, descriptor ownership, and stale-event
  rejection after descriptor/registry-slot reuse.
- Cooperative main-task shutdown, removal of abandoned channel waiters,
  repeated runs, independent runtimes, and deadlock reporting.
- GCC and Clang builds, concurrency and failure-injection tests, sanitizer
  checks, and equivalent C/Go benchmarks.

The next parts of milestone 0 are sysmon and scheduling/performance work. Full
Perl integration and deployment tooling remain later milestones. The design's
million-task and within-2x-of-Go targets have not been achieved or validated.

## Build and run

Requires Linux x86-64, GCC or Clang with C11 support, GNU Make, pthreads, and
GNU `timeout` for the test/benchmark targets. Go 1.21 or later is optional,
for comparisons only. There are no downloaded dependencies.

```sh
make
./build/hello
./build/select
./build/echo
./build/blocking
make test
make stress
make ubsan
make tsan
make memcheck # optional: requires Valgrind and its development headers
make BUILD=build/clang CC=clang test
```

`make` produces `build/libwump.a` and channel, timeout, socketpair echo, and
blocking pipe examples. The public API is
[runtime/include/wump.h](runtime/include/wump.h).

```c
#include <stdio.h>
#include <stdlib.h>
#include "wump.h"

static void sender(void *arg) {
	int value = 42;
	if (wump_chan_send(arg, &value) != 0) {
		abort();
	}
}

static void program(void *arg) {
	(void)arg;
	wump_chan *ch = wump_chan_make(sizeof(int), 0);
	if (ch == NULL || wump_go(sender, ch) != 0) {
		abort();
	}
	int value;
	if (wump_chan_recv(ch, &value) != 1) {
		abort();
	}
	printf("%d\n", value);
	wump_chan_free(ch);
}

int main(void) {
	return wump_run(program, NULL, 0) == 0 ? 0 : 1;
}
```

Compile a caller with `cc -std=c11 -pthread -Iruntime/include program.c
build/libwump.a -o program`. `wump_run` uses the requested number of execution slots;
0 selects the online CPU count. The caller participates as worker 0, and
its main task may be stolen and run by another worker. Slot IDs are stable
indices, not OS thread IDs. `WUMPPROCS` is not
implemented yet.

## Running Perl tasks

The Perl integration targets Perl 5.42.2, matching the installed Perl
and the design's 5.42 base. The private fork can run Perl closures as runtime
tasks, send scalar values and references through channels, yield, and sleep.
This is a single-slot prototype; Perl code does not yet run on multiple cores.
The build does not install or replace system Perl.

```sh
make perl-fetch                 # downloads, verifies SHA512/size, and unpacks
make perl-build                 # task-aware MULTIPLICITY + USE_ITHREADS build
make perl-example               # Perl tasks return 1, 4, 9, 16
make perl-regex-example         # yielding tasks retain separate regex captures
make perl-local-example         # spawned tasks inherit separate local bindings
make perl-elements-example      # tasks localize individual shared hash elements
make perl-pocket-example        # native pocket keyword keeps a binding in this act
make perl-test                  # task behavior, failures, shutdown
make perl-upstream-test         # upstream regex, aggregate and interpreter regressions
make perl-memcheck              # task suite with registered C stacks and full Perl teardown
make perl-source-test           # offline source acquisition failure tests
```

For an existing release archive, use
`make perl-build PERL_TARBALL=/path/to/perl-5.42.2.tar.xz`.
`PERL_JOBS=4` controls build parallelism. Run the Perl targets serially;
concurrent invocations against the same generated tree are unsupported.
Source, configuration, and build
outputs stay under `build/perl/`; the release archive is pinned by
[perl/upstream.lock](perl/upstream.lock). Existing unrecognized source trees
are preserved and rejected. `make clean` removes these private build outputs
along with the runtime build outputs, so keep editable fork changes in
repository patches rather than only in the generated source tree.

The prototype runs on one execution slot with separate task stacks and
channel operations:

```perl
use v5.42;
use Wump;

run {
	my $results = chan(2);
	for my $number (1..4) {
		act { $results->send($number * $number) };
	}
	say scalar $results->recv for 1..4;
};
```

These are exported functions from `Wump`, rather than the design's eventual
core feature syntax. `act` accepts a block and returns nothing. `chan()` is unbuffered;
`chan(N)` has N slots. `send` copies its scalar, preserving reference identity.
`recv` returns a value in scalar context, or `(value, ok)` in list context;
`ok` is false once a closed channel is drained. `undef` remains a valid message.
`close` wakes waiting tasks; duplicate close and send-after-close throw within
the task. `yield` and `sleep(SECONDS)` schedule cooperatively. These operations
require a running task; channels cannot outlive their `run`.

The main block returning abandons other tasks. A caught `die` stays within
its task. An uncaught task exception stops the run, prints its task ID and
error, and exits the process with status 2, including inside an outer `eval`.
Full task stack traces are still pending. Deadlock returns a catchable runtime
error to the surrounding Perl caller, and later runs remain usable.

The fork redirects execution state through a task pointer instead of copying
interpreter globals at every switch. Each task owns its Perl stacks, exception
state, default scalar, arguments, and separate pad frames for called subs.
Captured and `state` lexicals retain their shared identity. Stashes and op
trees belong to one interpreter; tasks do not clone interpreters. The original
interpreter fields remain as the root context outside `run`; the design's full
`aTHX`/per-task/per-P/process-global split remains future work.

Regex match state is task-local. Numbered and named captures, capture offsets,
`/p` values, `$^R`, named-capture hash iterators, match-once flags, and `/o`
caches survive yields without taking another task's results. Runtime `/o`
patterns compile on their first evaluation in each task. Regex code blocks
and substitution replacements can yield; `qr` values retain their captured
lexicals when sent to another task or retained after a run. An empty pattern
still uses the calling task's previous pattern, and tied match inputs still
receive their normal magic callbacks.

Instances are created lazily from the compiled pattern. Each PMOP has a unique
identity so a recycled Perl regex-pad offset cannot retrieve an old task's
instance. Tasks own mutable match data and named-capture iteration state;
compiled pattern storage can be retained through Perl's regexp copy support.
Entries for retired regex operations remain cached until the task ends.
Shutdown releases these references and regex callback frames while their Perl
and C stacks are still available. `pos()` remains a property of the scalar
being matched: using one shared string also shares its position.

Parallel Perl additionally needs the shared-value, reference-counting, and
pad-pooling changes described in [the design](DESIGN.md).
Enabling `USE_ITHREADS` prepares Perl's op-sharing infrastructure; it does
not add `threads.pm` compatibility or implement task isolation by itself.

Ordinary package scalar, whole-array, and whole-hash `local` bindings belong
to the calling task. They survive yields, unwind on return or caught exceptions,
and leave the global slots intact. Glob aliases see the same binding; references
taken before localization retain the original value's identity. A spawned task
inherits a snapshot of its parent's visible bindings. Scalar values and aggregate
elements are copied shallowly, so referenced objects remain shared. Parent scope
exit and later assignments do not change the child's inherited slots. Bindings
localized outside `run` retain ordinary Perl behavior; they are not task snapshots.

Ordinary array/hash elements and slices also support task-local `local`.
Their bindings follow the aggregate's identity, including through references
and glob aliases. Missing entries, hash-key deletion masks, array extent and
negative indices are part of the task's view. Whole-container reads, `exists`,
`keys`, `values`, and hash iteration see this view. Writes to unlocalized cells
remain shared. Child tasks inherit shallow snapshots of visible element bindings;
hidden outer bindings are not retained. The base aggregate keeps its own scalar
cells, so a reference obtained before localization still addresses the base value.

Structural mutation in a task with active element bindings currently raises an
error. This includes whole-container assignment/clear, array resizing,
push/pop/shift/unshift, splice, in-place sort/reverse, and array-element deletion.
Another task without those bindings can mutate the plain base aggregate; later lookups
in the localized task observe changes to its unlocalized cells. Hash-key deletion
is supported: deleting a localized key masks it in that task without deleting the
base key. Hash iteration uses a merged view; mutating a hash during iteration can
restart that view. Iterator views are released at scope exit and task cleanup.

`delete local`, typeglob/reference-alias localization, and localization of magic
variables (including tied values and interpreter settings such as `$/`) raise
errors inside tasks. Restricted hashes and symbol-table elements are also rejected.
Aggregates must remain nonmagical throughout a binding's lifetime.
Spawn rejects magic values inside inherited bindings before invoking any `FETCH`
hooks. Localizing a whole plain aggregate
and then assigning its elements is supported. Symbol-table replacement while a
binding is active is not supported. These limits keep the remaining shared-state
paths explicit while their isolation is developed.
Native code that accesses AV/HV storage directly or uses stock element
save-stack APIs still needs adaptation to the task's views.

`use Wump` also enables the native `pocket` keyword in that lexical scope.
It has `local`'s syntax, precedence, empty initial values and dynamic lookup:

```perl
local  $Request::ID = 'inherited context';
pocket $Request::ID = 'this act only';
act { report() };  # sees 'inherited context'
report();         # sees 'this act only', even if report was defined elsewhere
```

A pocket binding belongs to the current act and ends when its enclosing block
exits. Called functions see it; spawned acts skip it and inherit the nearest
ordinary `local` binding, or use the global slot when there is none. Nested
pockets are skipped, and an explicit ordinary `local` inside a pocket scope
makes that new binding inheritable again. Whole-array/hash snapshots also
exclude pocketed elements, keys, deletion masks and array extent. References
retain their ordinary shared identities, including explicitly captured references
to pocket values. Lexical `my` variables keep their usual closure-capture rules.

Pockets currently support the same plain package variables, elements and slices
as task-local `local`, with the restrictions described above. Executing `pocket`
requires a running `run`/`act`; lexical scalar targets remain invalid, as with
`local`. `no Wump` disables the keyword within its lexical scope. Qualified
names, method names and hash keys retain normal lookup. The keyword is an
experimental part of the private fork, not a stock Perl feature.
`B::Deparse` preserves pocket declarations so recompiling its output keeps
their inheritance policy.

This prototype does not implement `sel`, `scope`, `lock`, safe-point
preemption, or automatic Perl I/O/XS handoff. Ordinary blocking Perl operations
still occupy the single slot. Compilation/mutation of existing subs while
tasks are suspended and debugger/general multicall integration are not supported
yet. Scope-exit destructors see the enclosing binding and can spawn tasks.
Abandoning a task suspended inside a destructor remains unsupported, and
destructors invoked during task teardown cannot schedule. Task teardown
releases abandoned Perl frames and their owned values while their C stacks
are still mapped; it is not cancellation
that resumes the task's ordinary code.

## Channel selection and timers

`wump_sel(cases, ncases, timeout_ns, &chosen)` performs exactly one channel
operation. It returns 1 for a selected case, 0 for timeout/default, or -1
for a call/allocation error. `chosen` reports the original case index, or
SIZE_MAX on timeout; it may be NULL. Each `wump_case` contains a channel,
WUMP_SEND/WUMP_RECV, a payload pointer, and the selected operation's result.

```c
int value;
wump_case cases[] = {
	{ results, WUMP_RECV, &value, 0 },
	{ jobs, WUMP_SEND, &job, 0 }
};
size_t chosen;
int ready = wump_sel(cases, 2, INT64_C(50000000), &chosen); /* 50 ms */
/* ready == 1: inspect cases[chosen].result and handle that operation.
 * ready == 0: timed out. ready == -1: inspect errno via a TLS-safe accessor. */
```

Timeout -1 waits indefinitely; 0 polls without parking, implementing a
default case; positive values bound the wait in nanoseconds. NULL channels
disable individual cases. Duplicate channels and mixed send/receive cases
on the same channel are supported; a selection never communicates with
itself. Multiple ready cases are polled in randomized order, following the
[Go selection model](https://go.dev/ref/spec#Select_statements).

A selected receive reports result 1 for data, or 0 for a closed/drained
channel and zeros its destination. A selected send reports result 0 on
success, or -1 with EPIPE when closed; selecting that send still makes
`wump_sel` return 1. Only the chosen operation changes outputs. Timeout
leaves case results/data alone, and validation/allocation errors also leave
the chosen index alone. Unrepresentable monotonic deadlines fail with
EOVERFLOW. [examples/select.c](examples/select.c) demonstrates a complete
exchange and joins the worker before freeing channels on either outcome.

`wump_sleep(duration_ns)` parks just the task; 0 yields and negative
durations fail with EINVAL. Timers use CLOCK_MONOTONIC and a per-runtime
binary heap. Workers check expiry before selecting runnable work, and idle
workers use a
[monotonic condition-variable deadline](https://www.man7.org/linux/man-pages/man3/pthread_cond_timedwait.3p.html).
Timers register on the scheduler stack after the task context is saved.
Channel and timer wakeups compete through the same atomic winner; the
resumed task removes losing waiters and cancels its timer before returning.

## Blocking native calls

Use `wump_blocking(fn, arg)` around a known blocking C callback, or bracket
a native call with `wump_syscall_enter()` and `wump_syscall_exit()`. Check
enter's result before making the call: replacement allocation, condition
initialization, or thread creation can fail. Failure leaves the task on its
original execution slot and does not invoke the callback.

```c
if (wump_syscall_enter() != 0) {
	/* Report setup failure without making the blocking call. */
	return;
}
ssize_t result = read(fd, buffer, size);
/* Native errno remains on this OS thread until exit saves it. */
if (wump_syscall_exit() != 0) {
	/* Invalid/unmatched exit; correctly paired exit succeeds. */
	return;
}
/* Back on an execution slot; the task may have moved OS threads.
 * Inspect result and read errno via a TLS-safe accessor on failure. */
```

The callback/marked call stays on the caller's coroutine stack and OS
thread. Enter hands its execution slot (P) to an idle or newly created OS
thread (M), which runs that slot's existing queue and caches. The blocked
thread keeps the task until exit; exit saves its context on the scheduler
stack and enqueues it before releasing the native-call liveness count.
Normal code resumes only after a thread with a P dispatches it, preserving
the `wump_nprocs` execution limit. Native calls themselves can overlap beyond
that limit. This implements the explicit known-blocking path described by
[Go's syscall handoff](https://go.dev/src/runtime/proc.go), without automatic
sysmon detection yet.

`wump_blocking` returns 0 when the callback was invoked and returned through
a valid exit, or -1 on setup/API failure. The callback reports its own
result through `arg`; its errno is preserved across exit. Both markers also
preserve errno on success, along with the normal task context and floating
point state. [examples/blocking.c](examples/blocking.c) demonstrates a
blocking pipe read whose writer and timer progress with just one slot.

During the marked region `wump_worker_id()` is -1 and `wump_nprocs()` still
reports the configured slot count. Calls requiring a running task
(spawn, channel send/receive/close, selection, sleep, and I/O) fail with
EINVAL; yield does nothing. Allocation/free and queries valid outside a
runtime remain valid. Nested enter reports EBUSY; unmatched exit reports
EINVAL. Returning from a task without its matching exit reports EPROTO.
The convenience callback must return normally and must not call the
markers itself, schedule runtime work, call pthread_exit, or longjmp out.
Release native thread-owned locks before exit, which can migrate the task.

Idle native threads are reused until `wump_run` returns. The OS thread count
can therefore grow with the peak number of simultaneous blocking calls,
in addition to execution-slot threads and the optional netpoller. Shutdown
rejects new handoffs with ECANCELED, waits for entered native calls to
return, joins all runtime threads, and only then reclaims stacks. Native
calls cannot be forcibly canceled or bounded by a wump timer; use a native
timeout where needed. Task code after exit may be abandoned during shutdown,
so clean up non-runtime-owned resources inside the callback or in its owner
outside the run. Fork, signal/Perl/XS callback reentry, unmarked blocking-call
detection, and deferred syscall retaking remain future work.

## Socket and pipe I/O

Call `wump_io_open(fd)` from a task to transfer ownership of a socket or pipe
to its runtime. It sets O_NONBLOCK and FD_CLOEXEC; on attachment failure the
caller retains ownership and the original flags are restored. Regular
files are not supported by epoll. Borrow the native descriptor with
`wump_io_fd` for configuration/inspection, keeping the handle open while
using it. Never close/reuse that descriptor or attach it to another owner.
O_NONBLOCK also affects any duplicated descriptors for the same open file.

`wump_io_wait(io, WUMP_IO_READ | WUMP_IO_WRITE, timeout_ns)` returns ready
bits, 0 for timeout, or -1 for an error. Timeout units and -1/0 meanings
match `wump_sel`. Readiness is a snapshot and can be stale; direct native
I/O must still handle EAGAIN. One reader and one writer can park on a handle
at the same time; an overlapping parked wait returns EBUSY.

`wump_io_read`, `wump_io_write`, `wump_io_accept`, and `wump_io_connect` try
nonblocking syscalls and park on readiness when necessary. The timeout
bounds the entire retry loop. Would-block at zero timeout reports
ETIMEDOUT. Read/write return partial results as POSIX does; EOF returns 0,
and write retains write(2)'s SIGPIPE behavior. Accept returns another owned,
nonblocking, close-on-exec handle. Connect waits for EINPROGRESS/EALREADY
completion and checks SO_ERROR and the connected peer; other connect
errors, including Unix-domain backlog EAGAIN, propagate to the caller.
Closing the handle abandons a connection attempt that timed out.

`wump_io_close` interrupts parked operations with EBADF while leaving the
handle allocated. `wump_io_free` closes and frees, but reports EBUSY until
all in-flight calls have returned. Join those tasks before freeing; no new
calls may begin concurrently with free. Handles belong to one runtime;
foreign-runtime use fails with EXDEV. Shutdown stops and joins its poller,
detaches pending waits/timers, and closes/frees every remaining I/O handle.
Handles cannot be retained after `wump_run` returns.

Each runtime lazily starts one helper thread, epoll instance, and eventfd
on its first attachment. It uses
[EPOLLET with EPOLLONESHOT rearming](https://www.man7.org/linux/man-pages/man7/epoll.7.html).
Rearming rechecks current readiness, covering arrivals between EAGAIN and
parking. Timer and epoll wakeups claim one shared atomic winner after the
task's stack is saved. External wakeup publication updates the scheduler's
I/O count and run queue under the same lock, preventing false deadlocks.
Kernel events carry slot/generation tokens, not pointers to freed handles.
Nonblocking syscalls and close serialize under the poller mutex so an fd
cannot be closed/reused between lookup and the syscall. Linux
[close errors are not retried](https://www.man7.org/linux/man-pages/man2/close.2.html).

This is an initial implementation: the poller uses a shared mutex and a
separate thread, and the echo benchmark exposes a large latency gap versus
Go. Automatic DNS/regular-file wrappers, PerlIO integration, fork/signal
integration, and mixing I/O cases directly into `wump_sel` remain future
work. I/O calls currently take their own timeout argument.

## Scheduling and lifetime rules

Scheduling is cooperative. Tasks must return, call `wump_yield`, or park in
a channel operation, sleep, or I/O wait to let their worker run something
else, or enter a marked native call. An operation
that succeeds immediately need not yield. Unmarked native blocking calls
still occupy their execution slot; a task that never yields or a native
call that never returns can delay shutdown indefinitely.

Tasks may migrate. Do not retain native TLS addresses, including cached
`&errno` pointers, or hold native thread-owned locks across scheduling
points. The C compiler can cache TLS pointers across function calls; use a
separate non-inlined accessor if C task code reads/writes `errno` across a
yield (as the test does). This runtime is a foundation for a task-aware
interpreter; it cannot make arbitrary C TLS task-local. Runtime retry loops
use non-inlined errno accessors so they do not retain a native TLS address
after resuming on a different worker.

Task arguments and referenced data remain the caller's responsibility.
Sending copies bytes, including any pointer values; it does not copy the
referenced storage. Keep task arguments alive until their users finish.
Zero-sized channel elements allow synchronization with NULL payloads.

The caller owns channels and must free them. No new operations or parked
waiters may remain when a channel is freed. Freeing after a rendezvous or
close waits for the waker's final channel unlock. Do not share a channel
between independently running runtimes. All channels and buffers
referenced by a selection must remain alive until
that selection returns, including its losing cases. Sequential reuse is
supported; shutdown removes abandoned waiters and timers before unmapping
their stacks. Shutdown does not close or free channels or run abandoned
tasks' cleanup code.

All parked tasks with no runnable work, pending timers, active I/O waits,
or entered native calls produce `wump_run == -1` and `errno == EDEADLK`.
An open handle without an active wait does not prevent deadlock reporting.
Timers cannot interrupt a running task
that does not yield. Invalid API calls
report EINVAL; nested runs report EBUSY; send/close on an already closed
channel report EPIPE. A receive on a closed, drained channel returns 0 and
zeros the destination.

Each stack currently uses an `mprotect` guard. Linux VMA limits can bound
the number of concurrent tasks; mapping/guard failures are reported to the
caller. `MADV_GUARD_INSTALL`, stack-size configuration, and large-population
validation remain future work.

## Verification

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
AddressSanitizer fiber integration is not implemented yet.

`make memcheck` builds a separate variant with
[Valgrind stack registrations](https://valgrind.org/docs/manual/manual-core-adv.html)
and checks the behavior and failure suites for invalid accesses and
definite/indirect leaks. Logs go to `build/valgrind/`. Only the intentional
guard-page write disables Memcheck error reporting, in the child that must
still terminate with SIGSEGV; ordinary tests retain full error reporting.

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

## Benchmarks

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

[baseline.csv](bench/baseline.csv) records a 100,000-iteration run on
2026-10-23 with GCC 14.2.1 and Go 1.26.5 (`GOEXPERIMENT=nodwarf5`,
Linux amd64). It shows compute scaling while exposing substantial remaining
spawn overhead. [select-timers.csv](bench/select-timers.csv) records the
expanded suite on 2026-10-24 with the same toolchain, including selection
and sleep. [netpoller.csv](bench/netpoller.csv) adds the Unix socketpair echo
baseline; it does not measure TCP networking.
[syscall-handoff.csv](bench/syscall-handoff.csv) adds the blocking pipe case
on 2026-10-25 with the same toolchain. The machine reports 16 online CPUs;
these figures do not establish behavior on other hardware or long-running
workloads.
