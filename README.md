# wump

Go-style parallel concurrency for Perl. The [design](DESIGN.md) describes the
Perl fork and its standalone C runtime. This checkout implements the first
runtime slice on Linux x86-64; it does not yet run Perl programs.

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

The next parts of milestone 0 are sysmon and scheduling/performance work. Perl
integration and deployment tooling remain later milestones. The design's
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
