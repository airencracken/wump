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
- Buffered and unbuffered channels with byte-copy values, FIFO waiters,
  close/drain semantics, and wakeups after the parked task's stack is saved.
- Cooperative main-task shutdown, removal of abandoned channel waiters,
  repeated runs, independent runtimes, and deadlock reporting.
- GCC and Clang builds, concurrency and failure-injection tests, sanitizer
  checks, and equivalent C/Go benchmarks.

The next part of milestone 0 is `sel` and timers, followed by the epoll
netpoller, syscall handoff, sysmon, and scheduling/performance work. Perl
integration and deployment tooling remain later milestones. The design's
million-task and within-2x-of-Go targets have not been achieved or validated.

## Build and run

Requires Linux x86-64, GCC or Clang with C11 support, GNU Make, pthreads, and
GNU `timeout` for the test/benchmark targets. Go 1.21 or later is optional,
for comparisons only. There are no downloaded dependencies.

```sh
make
./build/hello
make test
make stress
make ubsan
make tsan
make memcheck # optional: requires Valgrind and its development headers
make BUILD=build/clang CC=clang test
```

`make` produces `build/libwump.a` and the channel example. The public API is
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
build/libwump.a -o program`. `wump_run` uses the requested number of workers;
0 selects the online CPU count. The caller participates as worker 0, and
its main task may be stolen and run by another worker. `WUMPPROCS` is not
implemented yet.

## Scheduling and lifetime rules

Scheduling is cooperative. Tasks must return, call `wump_yield`, or park in
a channel operation to let their worker run something else. An operation
that succeeds immediately need not yield. Native blocking calls block the
worker; a task that never yields can delay shutdown indefinitely.

Tasks may migrate. Do not retain native TLS addresses, including cached
`&errno` pointers, or hold native thread-owned locks across scheduling
points. The C compiler can cache TLS pointers across function calls; use a
separate non-inlined accessor if C task code reads/writes `errno` across a
yield (as the test does). This runtime is a foundation for a task-aware
interpreter; it cannot make arbitrary C TLS task-local.

Task arguments and referenced data remain the caller's responsibility.
Sending copies bytes, including any pointer values; it does not copy the
referenced storage. Keep task arguments alive until their users finish.
Zero-sized channel elements allow synchronization with NULL payloads.

The caller owns channels and must free them. No new operations or parked
waiters may remain when a channel is freed. Freeing after a rendezvous or
close waits for the waker's final channel unlock. Do not share a channel
between independently running runtimes. Sequential reuse is supported;
shutdown removes abandoned waiters before unmapping their stacks. Shutdown
does not close or free channels or run abandoned tasks' cleanup code.

All parked tasks with no runnable work produce `wump_run == -1` and
`errno == EDEADLK`. This assumes the runtime has no external event sources;
timer and I/O integration will extend the idle protocol. Invalid API calls
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
capacities 0/1/7/256. `make stress` repeats the behavior suite ten times.

The failure suite injects allocation, mutex/condition initialization,
stack mapping/protection, and partial thread-start failures. It checks
that started threads are joined, stack mappings are released, the main
task never runs on failed startup, and subsequent runs/spawns still work.

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

## Benchmarks

```sh
make bench
make bench-compare
make bench-compare ITERATIONS=1000000
```

CSV output reports spawn/completion, voluntary yield, unbuffered round trips,
a buffered 4-producer/4-consumer channel, and four compute tasks at 1 and 4
workers. Both implementations check message counts/checksums and use the
same work sizes and buffer capacities. Spawn uses batches of at most 1024
tasks, so it does not measure a million simultaneously live tasks. The
small stack cache intentionally makes this workload expose mapping churn.
Each CPU operation is one xorshift iteration; ping-pong operations are
whole round trips. Setup of the runtime itself is excluded from timings.

The Go comparison builds locally with networking and telemetry disabled,
and keeps its build cache under `build/`. Treat measurements as local
baselines, not stable performance claims; repeat on an idle machine before
drawing conclusions.

[baseline.csv](bench/baseline.csv) records a 100,000-iteration run on
2026-10-23 with GCC 14.2.1 and Go 1.26.5 (`GOEXPERIMENT=nodwarf5`,
Linux amd64). It shows compute scaling while exposing substantial remaining
spawn overhead. The machine reports 16 online CPUs; these figures do not
establish behavior on other hardware or long-running workloads.
