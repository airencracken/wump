# wump: Go-style parallel concurrency for Perl

Named for Mr. Gump's seven-hump Wump (Dr. Seuss): a camel with many humps.

Bring Go's concurrency ideas into Perl without losing what makes Perl
Perl: goroutines (`act`), channels, `sel` (Go's `select`), M:N scheduling
onto real OS threads, Perl code running in parallel on every core.

## 1. Goals and principles

- `act { ... }` behaves like `go`: cheap, millions possible, scheduled M:N
  onto real OS threads, Perl code running **in parallel**.
- **Go's memory model, Perl's syntax.** "Don't communicate by sharing
  memory; share memory by communicating." Channels are the primary tool.
  Sharing is allowed, but synchronizing it is the programmer's job, as in
  Go. No implicit per-object locking.
- **Races are bugs, and they get caught.** Like Go: unsynchronized
  concurrent writes to a shared hash/array/scalar panic (best effort,
  cheap, like Go's `concurrent map writes`), and `perl -race` finds them
  reliably (like `go run -race`). Concurrent *reads* are always safe.
- **Perl stays Perl.** `local`, `die`/`eval`, `warn`, `defer`, closures,
  Try::Tiny, `$_`, regexes all keep working and mean what they mean today,
  extended per task where needed.
- Single-threaded Perl stays close to stock speed.
- Somewhat competitive with Go: runtime primitives (spawn, switch, channel
  op) within ~2x of Go; Perl compute scales near-linearly with cores.
  Per core it will stay an interpreter, roughly 20-50x slower than Go.
- **Deploy like Go:** `wump build` produces one static executable with
  the interpreter, runtime, every module and the program inside. No
  perlbrew, no cpanm, no local::lib, no system perl on the target (§6).

**Platform:** x86-64 Linux only for now; arm64 later; other OSes much
later.

**Non-goals:** multiple interpreters per process, `threads.pm`/ithreads
compatibility, binary compatibility with existing compiled XS (everything
gets rebuilt).

This is a **fork of perl5** (base: 5.42 maint). An XS module on stock perl
can't do it: refcounting, pads and interpreter globals all have to change.

## 2. What it looks like

```perl
use v5.42;
use feature 'act';                 # core feature in the fork

my $results = chan(64);            # buffered; chan() is unbuffered

for my $url (@urls) {
    act { $results->send(fetch($url)) }   # closure; $url per iteration
}
act fetch_all(\@urls, $results);   # call form: args evaluated by the
                                   # caller, like `go f(x)`

sel {                              # Go's select; `select` stays the builtin
    recv my $r from $results { say $r }
    send $job to $workers    { ... }
    after 1.5                { warn "timeout" }   # time.After
    default                  { ... }
}

my $workers = waitgroup;           # sync.WaitGroup-style explicit counter
for my $id (1..8) {
    add $workers, 1;
    act { work($id); done $workers }
}
await $workers;                    # $workers->add/done/wait also work

lock %cache;                       # Perl's existing `lock` keyword, now a
                                   # real mutex until the block ends:
                                   # mu.Lock(); defer mu.Unlock()
```

### Semantics
- **`act` returns nothing**, like `go`. Results come back through channels.
- **The interpreter owns the runtime.** With Wump enabled, ordinary
  top-level Perl code runs as the main act. The interpreter manages scheduler
  startup, parallel execution, and shutdown; application code uses `act` to
  spawn work directly.
- **No application-level `run { ... }` wrapper in the final interface.**
  Interpreter entry replaces the prototype's former exported `run` function.
  `act` keeps its Go-style spawn semantics. Wait groups provide explicit
  `add`/`done`/`await` functions and `add`/`done`/`wait` methods; they track
  registered work rather than lexical scopes or act ancestry. Perl's process
  `wait` keyword keeps its existing meaning.
- **Uncaught `die` in any task is a Go panic:** print the error and a
  stack trace for that task (`task 42 [running]:` plus the Perl call
  stack), then exit the whole program with status 2.
- **`eval` / `try` / Try::Tiny are `recover`.** They catch dies within a
  task exactly as today.
- **`warn` is warn:** it prints to STDERR and the task continues.
- **`defer` blocks** (perl 5.36+) run at scope exit within the task,
  including during a die, as they do today.
- **No killing tasks** (Go has none either). Cancellation is cooperative
  through a done channel: the `context.Context` pattern, in a small module.
  Every blocking op can be bounded with `sel { ... after N {...} }`.
- **`send` copies the scalar**, strings via COW, like Go copying a value.
  References are like Go pointers: both sides point at the same data.
- **The program exits when the main task returns**, same as Go.

### `local` is task-local
Dynamic scope follows the call stack, and each task has its own call
stack, so `local` affects only the localizing task and whatever it calls:

```perl
local $Data::Dumper::Indent = 1;   # this task only
$Data::Dumper::Sortkeys = 1;       # plain assignment: global, as always
act { print Dumper($x) };          # inherits Indent = 1 (spawn snapshot)
```

- **At spawn, a new task inherits a snapshot of its parent's `local`
  bindings.** That's the Perl-native version of passing a `context.Context`
  down. Later changes in either task don't affect the other.
- **`local $h{k}` / `local $a[i]` on shared aggregates** are task-local
  too, using the same overlay mechanism (§5.8).
- **`local $ENV{PATH}`:** `%ENV` is a per-task view. The real `environ`
  is materialized at `exec`/`system`/backticks, so a `local`ized
  environment reaches the child process.
- **`local $SIG{__DIE__}` and `$SIG{__WARN__}`** are task-local hooks.
  `$SIG{ALRM}` and `alarm` become a per-task timer. Real signal handlers
  (`INT`, `TERM`, `HUP`, ...) stay process-wide (§4).

### `pocket`: local that stays home
`pocket` is `local` that isn't inherited: same dynamic scoping, restored
at block exit the same way, but tasks spawned inside the scope don't get
the binding. They see whatever was visible before the `pocket`.

```perl
local  $Log::Level = 'debug';      # this task and tasks it spawns
pocket $Req::ID    = $id;          # this task only
pocket $SIG{__DIE__} = \&report;   # don't hand my die hook to children
act { work() };                    # sees Level = debug, not Req::ID
```

Same syntax as `local` (scalars, arrays, hashes, elements, slices, globs),
same overlay machinery (§5.8). It's still scoped, so it's not goroutine-
local storage, which Go deliberately doesn't have.

## 3. Architecture overview

```
 ┌──────────────── perl fork ─────────────────┐
 │ act/chan/sel ops, wait groups, task state   │
 │ escape tracking, task-local dynamic scope    │
 ├──────────────── runtime (C) ────────────────┤
 │ tasks+stacks │ scheduler │ channels/sel      │
 │ timers │ netpoller │ sysmon │ safe points     │
 └──────────── Linux x86-64 ───────────────────┘
```

The runtime is plain C with no Perl dependency, built, tested and
benchmarked against Go on its own first.

## 4. Runtime (Go's runtime, in C)

### Tasks and stacks
- Stackful coroutines with a hand-written x86-64 switch that saves
  callee-saved registers plus MXCSR and the x87 control word.
- **C stacks can't grow** (pointers into the stack, unlike Go's movable
  stacks), so each task gets a fixed-size virtual mapping, committed
  lazily. Default 256 KiB, more for the main task. Perl→Perl sub calls
  don't recurse on the C stack; sort, overload, tie, magic, DESTROY,
  eval-string and XS callbacks do.
- The task struct lives at the top of its own mapping (from libdill):
  spawning is one cache pop or one mmap, no malloc.
- Guard page under every stack. Plain `mprotect` costs a VMA each, and
  `vm.max_map_count` (65530 by default) caps us at ~32k tasks. Plan:
  `MADV_GUARD_INSTALL` (Linux 6.13+, doesn't split VMAs) when available,
  otherwise mprotect guards plus raising the sysctl. Unguarded stacks with
  a canary check on every switch-out are the last resort.
- `errno` is saved/restored per task on switch.

### Scheduler (G/M/P)
- **P** (processor): a run queue, `runnext` slot, caches. `WUMPPROCS` of
  them, default = CPUs.
- **M**: an OS thread. Needs a P to run Perl code. Extra Ms exist so
  blocking syscalls don't eat a P.
- Local run queues, global queue, work stealing (steal half), `runnext`
  for handoff locality (ping-pong stays on one core), spinning-M
  accounting so readying a task doesn't wake a thread every time.
- **Parking protocol:** a task never releases the lock that makes it
  findable while still on its own stack. It switches to the M's scheduler
  context, which runs an unlock hook (Go's `park_m`).
- **sysmon** thread: retakes Ps from Ms stuck in syscalls (>20 µs), flags
  tasks running >10 ms for preemption, drives timers when idle.

### Safe points
Go needs signal-based async preemption because compiled code has few safe
points. **We have one between every op:** interpreter state is consistent
there. A custom runloop checks a per-P flag at backward branches and sub
entry (every op if it's cheap enough). The same safe point is used for:
- **preemption** (fairness),
- **stop-the-world** (fork, global destruction, rare stash surgery),
- **deferred freeing**: memory retired from shared values is reused only
  after every P has passed a safe point (§5.4). This is our stand-in for
  what Go's GC guarantees: nothing is reused while a racing reader can
  still see it.

The single-P bridge now has an initial safe-point path: its custom runloop
polls `wump_checkpoint()` every 256 opcodes. The runtime yields through its
ordinary scheduler after a roughly 10 ms budget, measured from the first poll
of each dispatch. C tasks can use the same checkpoint API on multiple Ps;
their resumed work remains stealable. Automatic Perl checks currently defer
during compilation, auxiliary callback stacks, and teardown. This provides
compute-loop fairness without a sysmon thread or asynchronous interruption
of native code.
Global-queue polling occurs at least every 61 dispatches or after 10 ms of
elapsed scheduler time, whichever comes first. Expired timers and external
wakeups therefore do not wait behind sixty full compute quanta on a busy P.
It does not yet permit simultaneous Perl execution on multiple Ps.

### Channels and sel
Go's `hchan`: mutex, ring buffer, FIFO waiter queues. An unbuffered send
copies directly into a parked receiver's slot. `sel` locks the involved
channels in address order and enqueues a waiter on each; the first to
fire wins via CAS on the `sel`'s state, as in Go. Channels hold `SV*` at
the Perl level; the C layer is element-size generic. Closing semantics
match Go, except sending on a closed channel is a die (= panic).

### I/O, syscalls, signals
- **Netpoller** (epoll, edge-triggered). Sockets and pipes are put in
  nonblocking mode under PerlIO's unix layer; EAGAIN parks the task on
  the fd. `accept`, `connect`, `sysread`, `sleep` and 4-arg `select` all
  go through the runtime.
- **Regular files and unknown blocking calls** (DBI drivers, `system`,
  `waitpid`, `flock`): enter/exit-syscall markers release the P, Go's
  `entersyscall`. sysmon catches the rest.
- **XS is our cgo:** calls into XS go through the same syscall handoff
  unless the XS is marked non-blocking.
- **Signals:** Perl already defers dispatch ("safe signals"). Process
  signal handlers in `%SIG` run on a dedicated signal task, like Go's
  `os/signal`.
- **fork():** stop the world at safe points, fork; the child keeps only
  the calling task and restarts the runtime. `exec`/`system` are fine.

## 5. The interpreter

### 5.1 aTHX becomes the task
Build the fork with `MULTIPLICITY` (and the `USE_ITHREADS` op-sharing
infrastructure, see 5.6). Nearly every internal function already takes
`my_perl` as its first argument, so each task's C stack already carries
its own `my_perl`.

- Split `interpvar.h` (~400 vars) into three classes:
  - **per-task**: argument/mark/scope/save/tmps stacks,
    `PL_curstackinfo`/cxstack, `PL_op`, `PL_curcop`,
    `PL_curpad`/`PL_comppad`, `PL_curpm`, `PL_parser`, `PL_compcv`,
    hints, ...
  - **per-P**: allocator caches, arenas.
  - **process-shared**: stashes, `PL_strtab`, op trees, immortals,
    `@INC`/`%INC`. One interpreter per process, so these become **plain
    C globals**: no indirection.
- `my_perl` points at the task struct. Switching tasks = switching
  stacks; the `my_perl` in each frame is already right. `PERL_GET_CONTEXT`
  (TLS, for `dTHX` code) is set on switch-in.
- Coro has to copy ~30 globals on every switch; this design copies none.

### 5.2 Escape tracking
Go's compiler does escape analysis to decide what lives on the heap. We
do it at runtime to decide what can be touched by more than one task.

**Invariant:** every SV is either *owned* by one task, or *shared*. An
owned SV is reachable only from its owner's roots (pads, stacks) and from
other SVs that task owns.

- **Owned SVs** behave exactly as in stock perl: non-atomic refcounts,
  plain mutation. Single-threaded code never pays.
- **Shared SVs** (one flag bit) get atomic refcounts, read-side caching
  turned off (§5.4), deferred freeing and write-conflict detection
  (§5.3). **No implicit locks.**

The current prototype establishes a conservative atomic SV-head counter
baseline for all core SVs, plus scoped `lock` inside acts. Initial publication
barriers now track generic references through captures, channels, package
variables, inherited references, and stores into marked values. They use
extension magic and leave SV-head layout unchanged. The walk also follows
native class fields, shared pad constants, flagged XSUB payloads, and core
regex SV roots without executing callbacks. It does not yet prove ownership
for unmarked values: raw XS storage, IO internals, and custom regex-engine
private pointers remain audit boundaries. Owned/shared counter specialization,
no-cache reads, and deferred reclamation remain prerequisites for multi-core Perl;
the interpreter bridge still runs with one execution slot. Native counter
stress is deliberately restricted to a rooted SV without concurrent allocation,
data mutation, or final destruction. C++ XS standard refcount helpers use atomics;
direct legacy lvalue access remains subject to XS serialization.

The active-task selector now lives in native thread-local storage rather than
the shared interpreter header. Every lookup checks interpreter identity and
reloads TLS across task migration. A two-thread native fixture checks isolated
task fields and unchanged root state for two interpreter contexts. It does
not execute Perl opcodes concurrently; remaining allocation paths, interpreter caches,
publication mutation, and XS serialization still need their own gates.

An SV becomes shared when it escapes. The **escape barrier** runs at:
1. `act` closure creation: captured lexicals escape.
2. Storing a reference into a shared SV/AV/HV: the referent graph
   escapes (walked once; already-shared subgraphs stop the walk).
3. Package variables, globs, stashes and their contents: always shared.
4. Channel send: the value is copied; its referents escape, **unless** a
   referent's refcount is 1 (only the outgoing ref holds it). Then
   ownership simply **moves** to the receiver. Plain message-passing code
   never touches an atomic.

Escaping is one-way in v1.

### 5.3 Races: panic, don't lock
Like Go maps: shared AVs, HVs and SVs carry a "being written" bit. A
writer finding it already set, or a reader finding it set mid-operation,
dies with `concurrent write to shared hash` (or array/scalar). It's
best-effort and cheap: a plain flag, not an atomic. Correct programs
synchronize with:
- **channels** (preferred),
- **`lock VAR`**: Perl's existing `lock` keyword, today a no-op without
  ithreads. It becomes a real mutex attached to the variable, held until
  the enclosing block exits. It's not reentrant, like `sync.Mutex`;
  re-locking in the same task dies. It's a better fit than Go's version,
  since the lock lives on the data it protects.
- **wait groups** for explicitly registered work: `waitgroup()`, `add`,
  `done`, and `await`, or `Wump::WaitGroup->new` and `add`/`done`/`wait` methods.
  There is no implicit block or descendant membership.

**`perl -race`** is the race detector. It's a debug build that stamps the
owning task in every SV, checks every access against escape status, and
tracks happens-before through channels/locks/spawn, like `go run -race`.
It's also how holes in the escape barrier get found.

**What's guaranteed:** race-free programs are correct, concurrent reads
are always safe, and races are usually caught. Same deal as Go: a racy
program that slips past detection can misbehave. Torn writes to a
scalar's type, like Go's torn interface values, are the unprotected
corner.

### 5.4 Reads must not write
Perl reads often mutate:
- numifying a string caches the IV and upgrades the SV,
- stringifying a number caches the PV,
- `keys %h` resets the hash iterator,
- `//g` sets `pos()`.

For "concurrent reads are safe" to hold, **shared SVs never cache on
read**: conversions are computed each time. Hash iteration state for
shared hashes moves to a per-task side table, so `keys`/`values`/`each`
are reads, like ranging over a Go map. `pos()` stays a write.

The first scalar read barrier is implemented for published plain nonreference
SVs carrying only publication magic. Conversion backends for IV, UV, NV,
truth, PV, bytes and UTF-8 convert a deep private snapshot; scalar copies use
the same snapshot to avoid modifying source COW bookkeeping. Snapshots copy
valid raw representations and their public/private cache distinctions,
including dual values, unsigned numbers and boolean identity. Numeric/truth
macro fast paths read already cached fields under short reader claims.
Explicit mutable-buffer requests and internal string-force/UTF-8-upgrade paths
continue to operate on the original SV.

Snapshots are mortal in the caller's existing temporary scope, so successive
conversions and scheduler switches do not invalidate computed string results.
Each act has a nested read-frame chain, with a root-interpreter fallback
outside scheduling. Save-stack entries pin the source and restore the chain
on normal return, throw and abandoned-act teardown. Undefined-value diagnostics
map a snapshot back to its original source for variable-name reporting.
Reference/overload conversion and other magic still follow upstream paths.
Native inversion lists also retain their native conversion/copy paths despite
their low SV type number. Plain scalar copies add no save-stack entries,
allowing callers to copy keys while assembling localization save records.

Eligibility checks claim a published head before inspecting mutable flags or
magic. Snapshot capture uses an exception-safe mortal token for its read claim,
and roots the new copy through a private mortal owner before allocating its PV.
Successful copies release the source pin immediately. The inactive token later
collects deferred storage at the caller's normal temporary cleanup, so capture
completion cannot insert save records or invoke unrelated destructors during
native localization setup. An allocation exception releases both the reader
claim and the partially built copy on unwind.

All IV/UV/NV helpers, with and without GET magic, join the claim protocol before
their first flag test. Truth helpers do likewise, releasing their short claim
before FETCH or fallback conversion and reacquiring after FETCH returns. The
writer's own act may read and snapshot its value without a conflicting reader
claim. Foreign writers are rejected before any guarded header or buffer access.
Reference and magical callback internals retain their separate audit boundary.

Audited scalar write opcodes have entry wrappers that identify destinations
from the stack/pad before any original flag tests. The wrapped implementation
keeps its original control flow, including early returns and callbacks.
Assignment, inc/dec (including integer aliases), arithmetic and bitwise
assignment, concat and multiconcat participate. Postfix operations guard both
the input scalar and result pad. Multiconcat accounts for its lexical, stacked,
append and assignment target layouts. Recursive chop/chomp reenters a wrapper
for each child value; substring/vec setters claim the proxy's original target.

The mutation claim spans GET/SET and overload callbacks. Nested C API claims
belong to the same act; completion releases claims in reverse order and leaves
intentional core saves for their normal scope. Save-stack cleanup handles
exceptions and abandonment. This is destination coverage, not read exclusion
for every raw operand access or a transactional lock across multiple scalars.

Subroutine preparation can itself reject publication of a closure whose
captured value has a foreign writer. The just-pushed block remains `CXt_NULL`
until preparation succeeds, before installing subroutine-specific fields or
changing the subcontext index. Exception unwinding therefore sees initialized
block state and cannot restore an uninitialized caller pad or argument array.
Regressions retry failed first calls in both the main act and child acts.

Mutators that depend on conversion caches must be allowed to install them on
their original destination while owning its exclusive writer claim. Read-barrier
eligibility therefore excludes that owned destination, while explicit snapshot
capture continues to accept it. Mutable numeric conversion flags acquire a
writer claim; increment's integer probe uses that explicit path. In-place
downgrade and chop/chomp request mutable PVs. This preserves the upstream
algorithms rather than accidentally editing an owned read snapshot.

Encoded PV macros share the cached-PV borrow path. Compatible byte/UTF-8 buffers
remain borrowed through the caller's temporary scope; mismatches convert owned
snapshots. `or_null` tests definedness under the claim and preserves null/length
and warning behavior. Cached numeric reads allocate no lifetime token. Native
try-claim APIs report logical contention without throwing, allowing explicit
retry loops; their metadata mutex can still serialize with publication.

Native C/C++ regressions check unchanged source flags, bodies, PVs and COW
counts. Eight native readers exercise immutable, already published sources
using separate executor allocators and task stacks; full-core TSan and
Valgrind cover concurrency and teardown. Cached PV macros now acquire lifetime
pins as described below; regex read-cache isolation remains a separate gate.

The interpreter owns a reclamation domain with a side registry keyed by SV
head, a recursive metadata mutex, and a list of retired private SV owners.
Publication holds this mutex for its callback-free graph walk. Its recursion
suppression is native-thread-local, so another publisher cannot mistake an
unfinished graph for a completed one. Publication-marker removal invalidates
the classification even when a CV pad reuses its head without allocator free.
Returning a head to the allocator removes its registry node before reuse.

A borrow briefly claims a reader count while capturing storage, then leaves
a private mortal token in the caller's temporary scope. Tokens pin the source
head and current generation; they follow the task's stacks across migration.
The short reader claim prevents overlapping capture and mutation. A logical
writer claim belongs to the act, supports nested C APIs, rejects another act,
and has save-stack cleanup for throws and abandonment. Claims hold no pthread
mutex across a potentially yielding callback.

If the current generation has borrowers, the outer writer first builds fresh
storage and prepares a retirement record. Only then does it swap resources.
Scalars preserve their head, magic and stash while an unmagical private shell
owns the old XPVMG body and PV. Real arrays copy pointer storage and retain
elements. Ordinary hashes copy bucket chains, keys and value ownership,
including lazy-deleted iterator entries. The live container retains original
element SV identities. Old slots and HEs continue to own removed values.
The writer also retains the old shell until its C API returns, protecting
aliased source arguments. Pointer-relative `sv_chop` arguments are translated
to the fresh buffer. Byte-COW counters use bounded atomic retains and atomic
last-owner drops; splitting retains its old reference until copying finishes.

Generation counts prevent repeated detachment for borrowers of older storage.
Collection waits for every domain pin to leave, detaches the retirement list
under the mutex, then runs final decrements without it. A throwing destructor
requeues unprocessed records. This deliberately conservative policy can retain
unrelated storage behind a parked borrower. Quiescent interpreter clones get
fresh domains; cloning with outstanding borrows or mutations is rejected.

Native tests exercise concurrent publication, synchronized C API writes,
cross-executor reclamation/migration, COW aliases, allocation-failure atomicity,
and full teardown under TSan/Valgrind. Explicit AV/HV borrowing accepts ordinary
storage only and rejects borrows inside the owner's active mutation. Cached
plain PV reads inside the writer use private snapshots. This is not a general
lock for all Perl operations: direct opcode/XS fields, mutable-pointer lifetime,
magical storage, element-overlay base writes and other shared caches remain
audit boundaries. The Perl scheduler retains its single execution slot.

Ordinary published hash iteration now has act-local cursors. These share the
existing task iterator registry, but store visited keys rather than a cloned
hash of values. Each call scans the current raw bucket for an unseen key and
returns the original HE; no HE pointer survives in cursor state. This preserves
value aliases and permits same-act deletion without retaining deleted values.
Each act resets/exhausts independently. Children inherit no iterator progress.
Publication seeds the publishing act's cursor from any active root iterator;
same-act stores/deletes preserve visited keys, while a new element binding
switches that act to a fresh private view.
Native cloning of eligible hashes uses the raw-copy path, avoiding upstream's
save/restore writes to the source cursor.

Partial cursors pin their source hash. Reset and exhaustion transfer the pin
to a private mortal RV through `sv_setrv_noinc`; `newRV_noinc` would write the
shared referent's TEMP flag. The private RV keeps weakly dereferenced sources
alive through the remainder of the current operation. Abandoned-task cleanup
releases unfinished cursors. Empty hash iteration creates no source aux data.
Native stress covers long collision chains and immutable numeric-valued hash
clones, with source flags, storage, root cursor and randomization unchanged.

Visited keys require O(n) private storage; rescanning a collision chain can
cost O(k²) for k colliding keys. Iteration during insertion/resizing retains
Perl's unspecified semantics. Restricted/tied hashes, stashes and other hash
magic keep upstream paths; element overlays keep their existing private
views. Direct XS cursor fields and callbacks while copying magical values
remain audit boundaries. Concurrent writers and reclamation are still open.

Bodies and string buffers freed by writes to shared SVs are retired, not
freed. They're reused after every P passes a safe point (§4), so a
`char*` from `SvPV` stays valid until the op that fetched it ends. That's
how `pp_*` functions already use them.

Open: perl 5.40's reference-counted argument stack (`PERL_RC_STACK`)
would make every push of a shared SV an atomic increment. Probably build
without it, or exempt shared SVs.

### 5.5 Containers
Shared AV/HV: no locks. Resizes retire the old storage through deferred
freeing, so a racing reader sees the old table, never freed memory.
Writes are detected per §5.3.

### 5.6 What USE_ITHREADS already gives us
ithreads clones interpreters but **shares the op tree** read-only, so
perl already has the infrastructure for immutable ops:
- GV ops reference their GV through a pad offset, not a pointer in the op.
- `PL_regex_pad`: one REGEXP per PMOP per interpreter. We make it **per
  task, created on first use**, which fixes tasks clobbering each other's
  `$1`/`$&`.
- `OP_REFCNT_LOCK` for op refcounts.

Everything compiled before the main program starts (BEGIN-time subs,
stashes, constants) is **immortalized**: no refcount traffic at all.

### 5.7 Pads (Perl-specific)
Lexicals live in `padlist[CvDEPTH]`, stored on the CV, so two tasks in
the same sub would share `my` variables. Fix: the padlist becomes a
**pool**. Entering a sub claims a free pad (lock-free stack per CV),
leaving returns it. Recursion is just another claim. `CvDEPTH` becomes a
per-task recursion count used only for "deep recursion" warnings.
`state` vars and closure capture need a careful audit here.

### 5.8 Task-local dynamic scope
- **Always per-task** (no `local` needed): `$_`, `$@`, `$!` (errno),
  `$1`.. and `$&` (per-task `PL_curpm`), `$.`, the selected output handle,
  `@_`. Implemented as task slots behind `DEFSV`/`ERRSV` etc.
- **`local` overlay:** when a task `local`izes a glob slot or an element
  of a shared aggregate, the slot is flagged "has overlays" and the
  binding goes into the task's overlay table. Lookups of flagged slots
  check the current task's table first; unflagged slots take today's fast
  path. `local` on a task's *owned* data needs nothing new: no one else
  can see it.
- `$/`, `$\`, `$,`, `$"`, `$;` and friends are globals that people `local`,
  so they get the overlay automatically.
- **Spawn snapshot:** `act` copies the parent's active `local` overlay
  bindings into the child. Each binding carries a `pocket` bit, and
  pocketed bindings are skipped, so the child sees the value from before
  the `pocket`.
- **Process-wide:** `$0`, cwd, umask, `@ARGV`, `@INC`/`%INC`, real signal
  handlers. `%ENV` is a per-task view, materialized for exec.

### 5.9 Compilation and stashes
`eval STRING`, `require`, `do FILE` and runtime `*foo = sub {...}` take
one **compile lock**. Parser state is already per task (`PL_parser`), and
compiling at runtime is rare. Stash mutation takes the stash's lock;
method caches are invalidated through an atomic generation counter.

### 5.10 Allocation
Go's tiered allocator: per-P caches (`mcache`) → central per-size-class
lists (`mcentral`) → page heap (`mheap`). Perl's SV/body arenas already
are size classes, so they become per-P caches refilled from central
lists. String buffers use the same tiers. An SV freed on another P goes
to that P's cache; arenas are only memory.

The initial executor arena split is implemented. SV heads, body free lists,
arena registries, and signed allocation deltas use an interpreter-filtered
TLS selector independent of task identity. The one-P bridge activates its
executor cache on dispatch and cleanup, then merges it into the root
interpreter after scheduler shutdown. Merging retains live SVs and joins all
arena registries before global destruction. It neither frees arena memory
early nor requires the freeing executor to be the allocating executor.

A native eight-executor fixture allocates, validates, exchanges and finally
frees scalars, strings, references, arrays, and hashes concurrently against one
interpreter. It checks root-cache isolation, cross-thread cache handoff,
post-merge survival/reuse and complete teardown. A separate TSan build
instruments Perl's full allocation/destruction paths. This is not yet parallel
opcode execution: remaining read caches, shared-graph reclamation,
compiler state and XS still need isolation. Central cache refill is pending.
Perl memory-tracking builds and `-DD` arena scans are rejected by `use Wump`;
the initial caches target the private fork's system-malloc configuration.

Shared-key interning now serializes table lookup, insertion, growth, and
removal with a mutex per interpreter. Key retains use atomic reference
counts without changing HE/HEK layout. Candidate allocation and diagnostic
callbacks run outside the lock, followed by a second lookup before insertion.
The lock lives from interpreter construction through `perl_free`; cloned
interpreters initialize their own lock. Shared-key bytes and flags are
immutable after publication. Direct XS mutation of shared keys still needs
an audit before concurrent use.

Hash traversal randomness and the `nomemok` allocation-failure flag now
belong to executor state. The allocator initializer snapshots randomization
before concurrent execution; its stream does not merge back into the root.
Native stress keeps hash randomization and shared-key interning enabled,
forces table resizing with 8,192 live keys, and retires them across executors.
Legacy key release also normalizes ASCII/UTF-8/Latin-1 inputs consistently
with sharing, with a regression that fails on the earlier interpreter.

### 5.11 XS
Legacy XS isn't safe to run in parallel, so unaudited XS takes a global
**XS lock** unless the module declares itself parallel-safe. The core's
own ext/ modules get audited first (List::Util, Scalar::Util, POSIX,
Storable, ...).

## 6. Deployment: one binary, one tool

Half of what makes Go easy to ship is the static binary; the other half is
the `go` tool getting dependencies there reproducibly. We want both.

### The `wump` tool
```
wump run app.pl          # like `go run`
wump build -o app app.pl # static executable
wump test                # prove, with the project's deps
wump get Mojo::UserAgent # add a dependency, update the lock
```
- **`wump.mod`** lists direct dependencies (CPAN dists with minimum
  versions). **`wump.sum`** locks the exact resolved versions and their
  hashes, like `go.mod`/`go.sum` (Carton's cpanfile.snapshot is the Perl
  prior art).
- **Module cache** in `~/.cache/wump/` (like `GOMODCACHE`), keyed by
  dist+version and shared between projects. Nothing is ever installed
  into a global `site_perl`. A project only sees what it locked.

### What goes in the binary
- **Static libperl** (our fork) + the runtime.
- **XS modules linked statically.** Perl already supports static
  extensions: the generated `xs_init` calls each module's `boot_*`
  function directly, with no DynaLoader and no `.so` files.
- **Pure-Perl modules and the program** stored compressed in an ELF
  section, served by an `@INC` hook. Nothing is extracted to a temp dir
  (that's what PAR::Packer does, and we don't want it). `%INC` and
  `__FILE__` get virtual paths (`/$wump/lib/Foo/Bar.pm`), so `caller`,
  `Carp` and `FindBin` behave sensibly.
- **`use wump::embed 'templates/**'`**, like `//go:embed`: data files go
  into the binary and are read through normal filehandles. Share dirs
  (File::ShareDir) are embedded the same way.

### Finding what to bundle
- Static scan of `use`/`require` (Module::ScanDeps-style), plus the deps
  locked in `wump.sum`.
- Modules loaded by computed name (DBI drivers, Module::Pluggable
  plugins, `require $class`) get listed in `wump.mod`. A missing one dies
  with `Foo::Bar is not bundled; add it to wump.mod`, not a confusing
  `@INC` dump.

### libc and C libraries
- **Default: fully static against musl.** Glibc static binaries break on
  NSS/`dlopen` (`getpwnam`, some `getaddrinfo` setups). Musl's slow
  malloc doesn't matter since we bring our own allocator (§5.10). DNS
  goes through musl's resolver under syscall handoff (§4).
- **Option: dynamic against glibc only**, like Go with cgo, for targets
  that need it.
- **C library deps** (OpenSSL for IO::Socket::SSL, zlib, libxml2...) are
  built and linked statically from pinned sources. This is the one place
  we can't copy Go: Go avoided the problem with pure-Go crypto and
  networking. `Alien::*` modules are the pain point; we'll keep curated
  build recipes for the common ones.

### Startup time
Every run compiles every bundled module, which can take a second for
heavy Moose-style apps. Stretch goal: **snapshot the heap after the
compile phase** into the binary, so startup skips compiling. Perl's old
`perl -u`/undump idea, done properly. Hard; later.

### Prior art
FatPacker-style bundling gets you one *script*, but the target still
needs a perl, the right version, and any XS compiled for it. A wump binary
needs only a Linux kernel: the interpreter and the concurrency runtime
ship inside it, like Go's runtime ships inside every Go binary.
staticperl (Marc Lehmann) is the closest: static perl with embedded
modules and static XS. App::FatPacker does pure-Perl only. PAR::Packer
extracts to disk. perlcc/B::Bytecode are dead.

## 7. Testing and debugging
- perl's own `make test` must pass at every milestone.
- `perl -race` (§5.3).
- TSan build of the runtime: `__tsan_switch_to_fiber` etc. on every
  switch.
- Stress suite: N tasks hammering shared AV/HV/scalars/regexes/closures,
  correctly synchronized, on 16 cores: no crash, no race reports. Plus
  deliberately racy programs, which must panic or be flagged by `-race`.
- Benchmarks with Go equivalents in `bench/`: spawn 1M, ping-pong, MPMC
  channel throughput, parallel CPU (16 tasks), echo server via the
  netpoller.

## 8. Milestones
Each one ends in something runnable.

The first usable parallel preview should run an ordinary Perl worker pool:
closures share work through channels, compute across several executors, use
scoped locks for shared updates, and finish through wait groups. It must retain
Perl's numeric, string, magic and exception behavior, survive repeated startup
and shutdown, and demonstrate measured CPU scaling with correct results.

The remaining gates for that preview are operand and aggregate opcode audits,
regex/compiler/method-cache isolation, a compile gate and a defined policy for
unaudited XS, followed by enabling multiple interpreter execution slots and
testing real programs under migration and contention. Native opcode fixtures
validate parts of this path; they do not substitute for a parallel interpreter
run. General network-service usability additionally needs the Perl I/O handoff,
`sel`, and explicit signal/fork behavior. Assess readiness against these gates;
the amount of completed infrastructure is not a reliable time estimate.

0. **Runtime in C**: tasks, stacks, scheduler, channels, `sel`, timers,
   netpoller, sysmon. Benchmarked against Go.
1. **Fork, one P** (Go pre-1.5 defaulted to `GOMAXPROCS=1` too): interpvar
   split, `my_perl` = task, `act`/`chan`/`sel`/`lock`/`pocket` in core,
   explicit wait groups with functional and object interfaces,
   task-local specials and `local` overlays, panic semantics. Perl test
   suite passes.
   - Required entry integration: run ordinary top-level Perl as the main act
     and let the interpreter own scheduler lifetime. Remove the prototype's
     exported `run` function and migrate its examples and tests.
   - Acceptance: a Wump-enabled script creates a channel, spawns with
     `act { ... }`, and receives a result at top level without `run { ... }`.
     Verify spawn returns immediately, main-task exit ends execution, and
     explicit wait-group waiting remains separate. This entry integration can
     run on one P while parallel execution is still being brought up.
   - Implemented in the single-slot bridge: `use Wump` activates interpreter
     entry, top-level code is the main act, and the `run` wrapper is removed.
     Wait groups use explicit counters with functional and object calls;
     `scope` is removed. These are still module functions; core feature syntax
     and multi-P Perl remain open.
   - Automatic safe-point scheduling, executor allocator caches, atomic shared
     keys/refcounts, graph publication, scalar read claims, deferred storage
     reclamation, and the listed scalar write destinations are implemented.
     Native tests execute actual scalar opcodes with multiple executors. The
     listed binary arithmetic/comparison entries now snapshot plain published
     inputs before raw cache reads; native contention tests do not hold an
     external read claim around those opcode calls. Mixed magic/reference
     paths and operand lifetimes between container loads and opcode entry
     remain separate gates.
     Task-private special globs and localization anchors no longer create
     prototype CVs or participate in namespace backreference lists.
     The interpreter bridge remains single-slot until the remaining state gates
     below are closed.
2. **Many Ps for I/O**: Ms, syscall handoff, netpoller, fork(), signals.
   Perl code still runs on one P at a time behind a runtime lock; that's
   development scaffolding, never a shipped mode.
3. **Parallel Perl**: escape barrier, `-race`, atomic refcounts for
   shared SVs, no-cache reads, deferred freeing, write detection, pad
   pools, per-task regexes, compile lock, per-P allocator, XS lock. The
   scaffolding lock goes away.
4. **Performance**: close the gap with Go on the runtime benchmarks;
   runloop tuning; cheaper refcounts for hot shared values.
5. **Deploy like Go** (§6). Doesn't depend on parallel Perl: it can
   start as soon as the fork builds (after Milestone 1), and is a good
   early win.
   - 5a. `wump build`: static musl binary with libperl + runtime +
     static XS + embedded modules; `wump::embed`.
   - 5b. The `wump` tool: `wump.mod`/`wump.sum`, module cache,
     `wump get/run/test`, curated static C-library recipes.
   - 5c (stretch). Post-compile heap snapshot for fast startup.
6. arm64.

## 9. Open questions
- `state` vars under pad pools.
- Escape walks are O(n) on big structures the first time; measure.
- Preemption check every op vs branch/entry only: measure the runloop
  cost.
- DESTROY runs on whichever task drops the last reference. Fine?
- `PERL_RC_STACK` (§5.4).
