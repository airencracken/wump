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

The bridge has an initial safe-point path: its custom runloop
polls `wump_checkpoint()` every 256 opcodes. The runtime yields through its
ordinary scheduler after a roughly 10 ms budget, measured from the first poll
of each dispatch. The parallel Perl preview uses this path on each execution
slot. C tasks can use the same checkpoint API on multiple Ps;
their resumed work remains stealable. Automatic Perl checks currently defer
during compilation, auxiliary callback stacks, and teardown. This provides
compute-loop fairness without a sysmon thread or asynchronous interruption
of native code.
Global-queue polling occurs at least every 61 dispatches or after 10 ms of
elapsed scheduler time, whichever comes first. Expired timers and external
wakeups therefore do not wait behind sixty full compute quanta on a busy P.
Parallel Perl execution remains limited to audited paths by the compiler and
XS gates described below.

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

The current bridge preserves `aTHX` as the shared interpreter pointer for
compatibility with the existing core and XS layout. Task-field access instead
selects per-act storage through an interpreter-filtered TLS pointer, reloaded
after migration. Dispatch selects a per-slot allocator separately. This is an
implementation difference from the proposed task pointer above; it still uses
one interpreter and never creates or clones an interpreter for `act`.
Typed inline field accessors select the storage once per access. On x86-64
ELF, the selector loads through the current FS base with volatile assembly;
only the executable's TLS offset can be cached across calls. Other targets
retain the out-of-line selector. Neither path retains a native thread address
across migration. A sticky atomic flag bypasses task and allocator selection
until that interpreter first activates either context. Clearing a context
never clears the flag, since another executor may still be using it.
Cloning explicitly initializes the flag before the first locale-context switch
and after the debug allocator poisons the interpreter. A native regression
fills the clone allocation with nonzero bytes and checks that its first context
switch already sees an inactive interpreter.

Common opcode bodies also have generated active-context variants. Their C
invocation owns a particular act, so the dispatcher can retain that task's
pointer and root/main selection across callbacks and migration. These variants
inline the same patched native bodies and preserve custom ppaddr hooks,
checkpoints, signal checks and the compiler admission gate. Header inline
helpers and unaudited opcode bodies retain dynamic selection. No native TLS
address or per-executor allocator pointer is cached by this optimization.

Canonical default, error and regex-code-result scalar lookup uses the same
bounded helper in public accessors and generated active bodies. With no active
local bindings and no effective-glob alias, it returns the selected main/root or
private act GP's scalar slot. Other GVs, all bindings and aliases retain general
localization, regex-cell and publication handling. Selection neither allocates
nor calls Perl; it retains no cached result across a callback or scope change.

Before activation, common opcodes also have ordinary-context variants generated
from the same patched native bodies. Their state lvalues address the root
interpreter directly. The ordinary runloop uses these variants only when the
opcode retains its native public entry; custom ppaddr hooks still run. Once a
callback activates a context, dispatch returns to the guarded standard loop
before the next opcode. Atomic refcounts and shared-key safety remain enabled
even on the inactive path, including for foreign native threads.
Common opcode bodies and the native numeric setter bodies inline on this
path. A setter rechecks activation before its store and falls back to the
public guarded API if an earlier opcode callback activated a context.

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
no-cache reads, and deferred reclamation remain prerequisites for general
parallel safety. The bridge now has an opt-in parallel preview with conservative
atomic counters and audited value paths. The original native counter fixture
is restricted to a rooted SV; separate allocator and opcode fixtures exercise
allocation, mutation and final destruction. C++ XS standard refcount helpers
use atomics; direct legacy lvalue access still requires an audit.

The active-task selector now lives in native thread-local storage rather than
the shared interpreter header. Every lookup checks interpreter identity and
reloads TLS across task migration. A two-thread native fixture checks isolated
task fields and unchanged root state for two interpreter contexts. It does
not execute Perl opcodes concurrently. A separate Perl worker-pool test now
executes ordinary closures on several slots within the same interpreter.
Remaining interpreter caches, publication paths and XS still need auditing.

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

Bounded cached-IV add/modulo operations use an executor-local numeric reader
announcement instead of holding that mutex. An SC announcement followed by an
SC writer-gate probe pairs with writers' SC gate close and reader scan: either
the reader sees the closed gate, or the writer sees its active announcement.
The writer waits for release before touching registry or SV metadata. Readers
finding a closed gate withdraw and retry, retaining writer priority without
turning numeric operations into queued metadata writers. Numeric admission
still checks the original registry states, foreign writer claims and scalar
representation predicates before reading the source bodies or updating a
private target. There are no callbacks, metadata entry, allocation or scheduling
inside an admitted operation. Recursive metadata regions and native execution
without an executor slot use the original mutex path. The aligned slots are
bounded by executor count and freed at allocator merge, including runtime restart.
Returning to metadata writes unregisters the executor's inactive slot under the
mutex. Two eligible operations without intervening metadata writes warm a slot;
the next operation can use its announcement. Cold operations retain mutex
exclusion, and warming does not advance the metadata epoch or impede other
executors' warmup. Its next arithmetic burst reuses that allocation and registers
again under writer exclusion. Dormant executors therefore do not force every later
metadata write to fence and scan slots after isolated arithmetic operations.

Registry probes, sharing classification and pin/reader-count bookkeeping use
the same recursive mutex without closing the gate. They never change SV fields
or node membership. Published heads cannot be numeric targets; private scalar
classification belongs to the calling act, and implicitly shared GVs/stashes
are excluded by the numeric representation predicates. A completed logical
writer also releases its bookkeeping under that mutex: its release store of
access=0 publishes the completed storage changes to numeric readers' acquire
probes. Readers seeing the writer bit do not inspect those scalar fields.
New writer admission, publication, node removal and actual retirement collection
still drain numeric readers. A no-op collection can return after a registry-only
probe; pending reclamation rechecks pins under writer exclusion before removal.
Numeric admission rejects a published or claimed target from its registry node
before reading the head's type or flags. An inaccessible-page native regression
checks this order; a foreign logical writer may already be updating that head.

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
audit boundaries. The parallel Perl preview supports the audited paths;
these tests do not establish safety for arbitrary core or XS field access.

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

The current bridge additionally gives each act private scalar capture cells
and copies the mutable substring search caches used by parallel regex matches.
Numeric capture aliases and localization share the act's cell; namespace GP
retains/releases are guarded without holding metadata locks across callbacks.
Unicode inversion-list searches use atomic access to their shared last-index
hint. Finished acts retain private CV frames for destructor callbacks and drain
any new call or match caches before releasing their Perl stacks.
The general regex and compiler audits remain incomplete.

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

The preview currently rejects runtime string eval, require, do-file and regex
compilation with multiple slots, before compiler entry. Dependencies can load
at compile time. This is a temporary boundary until the compile gate exists.
Audited method/class-cache lookups and namespace backreference changes use
short native metadata guards. A lookup releases its guard before entering a
method body; scheduling from a callback inside the guard is rejected.
The creating act retains new MRO cache data through private mortal references,
so its scope cleanup never toggles flags on a cache head another act can read.

### 5.10 Allocation
Go's tiered allocator: per-P caches (`mcache`) → central per-size-class
lists (`mcentral`) → page heap (`mheap`). Perl's SV/body arenas already
are size classes, so they become per-P caches refilled from central
lists. String buffers use the same tiers. An SV freed on another P goes
to that P's cache; arenas are only memory.

The initial executor arena split is implemented. SV heads, body free lists,
arena registries, and signed allocation deltas use an interpreter-filtered
TLS selector independent of task identity. The bridge activates the current
slot's executor cache on dispatch and cleanup, then merges every cache into the root
interpreter after scheduler shutdown. Merging retains live SVs and joins all
arena registries before global destruction. It neither frees arena memory
early nor requires the freeing executor to be the allocating executor.

A native eight-executor fixture allocates, validates, exchanges and finally
frees scalars, strings, references, arrays, and hashes concurrently against one
interpreter. It checks root-cache isolation, cross-thread cache handoff,
post-merge survival/reuse and complete teardown. A separate TSan build
instruments Perl's full allocation/destruction paths, including concurrent
closure stash backreferences. Actual parallel opcode execution is checked by
the worker-pool suite. Remaining read caches, shared-graph paths, compiler
state and XS still need isolation for general use. Central cache refill is pending.
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

The preview rejects unaudited XS with multiple slots instead of providing the
planned compatibility lock. Audited XSUBs register their native entry address
with `Perl_wump_xs_allow(aTHX_ cv)` before program execution. Wump's own XSUBs
are registered; constant XSUBs are permitted. Single-slot execution keeps the
existing XS behavior. A compatibility lock must also account for callbacks and
reentry before it can safely replace rejection.

The first standard-library audits admit the Linux Time::HiRes wall/monotonic
clock readers and Unicode::Normalize NFC/NFD entry groups. Normalization uses
private plain-scalar snapshots and rejects unsupported input before allocating
its native buffers. The rest of each module remains gated. This enables the
dashboard's Unicode CPU backend to be measured on one, two and four slots;
the HTTP reactor, dynamic compilation and its remaining XS dependencies still
need their own acceptance gates.

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

An experimental preview now runs 16 workers over shared channels, uses scoped
locks, nested acts and wait groups, preserves caught exceptions over yields,
and checks repeated interpreter entry and shutdown. The tests verify one
interpreter, private act state and execution on multiple slots. `WUMPPROCS`
selects 1 through 256 slots, defaulting to 1. A private-buffer string benchmark
checks correct results and allows timing one, two and four slots; small
arithmetic workloads can regress from metadata contention.

This does not close the general operand/aggregate, weak/object-reference,
regex-cache, namespace-mutation or XS audits. Runtime compilation and
unaudited XS are rejected in multi-slot execution pending the compile gate
and compatibility policy described above. General network-service usability
additionally needs the Perl I/O handoff,
`sel`, and explicit signal/fork behavior. Assess readiness against these gates;
the amount of completed infrastructure is not a reliable time estimate.

### Implementation assessment (updated 2026-10-31)

The milestones below describe the intended development sequence. Work now
overlaps them: there is real parallel Perl execution, while some earlier
language and I/O integration remains open. The current status is an
experimental parallel preview; neither the broad compatibility milestone nor
the performance milestone is complete.

| Design goal | Current evidence | Remaining work |
| --- | --- | --- |
| One interpreter, M:N execution | Supported Perl closures run on several slots with private act state and per-slot allocation caches; tests verify interpreter identity and migration. | Generalize the supported paths through the remaining audits. `aTHX` still denotes the shared interpreter, with TLS selecting act storage. |
| Cheap tasks and runtime primitives | C tasks, guarded stacks, work stealing, channels, selection, timers, epoll and explicit syscall handoff are implemented and tested. | The within-2x-of-Go target is not met by the recorded spawn baseline. Sysmon, million-live-task validation and stack mapping costs remain open; stacks currently use mprotect guards. |
| Perl semantics and language surface | Main-act entry, closure spawning, scalar/reference channels, wait groups, scoped locks, regex state, `local` and `pocket` have focused coverage. | Perl `sel`, core feature/call-form syntax, per-act environment/process integration and remaining magic/weak/object paths need work. |
| Shared-memory safety | Conservative atomic counters, publication, read claims, private conversion snapshots and pinned storage retirement support audited paths. | General concurrent-read safety, ownership specialization, cheaper reclamation, remaining aggregate/cache/XS audits and a user-facing `perl -race` are unfinished. |
| Useful network services | The dashboard passes 48 live HTTP/WebSocket checks each on one/four slots; its Unicode job backend verifies results on 1/2/4 slots. Audited encoding and prepared listener cleanup complete the bounded four-slot path. | Automatic Perl I/O/syscall handoff, general XS compatibility, runtime compilation policy and longer network soaks remain separate design gaps. |
| Performance | The latest matched integer loop takes 0.92x stock time without Wump and 4.87x/2.50x/1.37x with one/two/four slots. Eight slots beat sequential stock on this fixture at two work sizes, including whole-process timing. Historical, fresh and application regression checks pass. | One-slot overhead, broad ordinary-Perl parity and the Go runtime target remain unmet. Eight-slot scaling is about 6.1x over one slot on the longer case. The earlier ordinary XS macro case measured about 2.12x stock and was not recaptured here; application metadata contention remains substantial. |
| Compatibility and validation | The latest standard noninteractive upstream harness passes 2,919 files / 1,351,237 checks. Project, full project ASan, targeted Clang/UBSan, native Memcheck and live Mojo checks pass. TSan passes 34/35 Perl suites and ten native drivers with negative controls. | The remaining TSan failure is the previously reproduced threads.pm clone race; full Perl MSan stops in uninstrumented locale dependencies. Helgrind/DRD abort internally on this host. General CPAN compatibility and longer network soaks remain unvalidated. |
| Deployment and portability | A private Perl fork and standalone C runtime build on Linux x86-64. | Static application bundling, the `wump` tool, dependency locking/cache and arm64 are pending. |

There are three material differences from the proposed architecture. `aTHX`
still points at the interpreter, with TLS selecting task state; unaudited XS is
rejected rather than protected by the planned compatibility lock; and runtime
string compilation is rejected rather than protected by a compile lock.
These preserve the preview's audited boundary but do not fulfill "Perl stays
Perl" for general programs. Moving setup into CHECK advances this dashboard;
it is not a general runtime-loading solution. Internal metadata locks protect
runtime invariants; programs still synchronize shared updates explicitly.
Development TSan builds do not implement the promised user-facing `perl -race`.

USE_ITHREADS supplies build-time op-sharing infrastructure. Acts never clone
the interpreter or load threads.pm to schedule work. The cloning regression
failure remains visible in the full TSan target, but ithreads compatibility is
an explicit non-goal and must not be mistaken for the implementation model.

The next acceptance priorities are:

1. Reduce one-slot Wump overhead and metadata contention exposed by the matched
   baseline below. Check ordinary-fork performance across more workloads.
   Preserve migration-safe state access, publication and reader
   semantics while optimizing. Retain raw samples, compiler configuration and
   source identity; separate startup from work timing. Recheck runtime
   primitives individually, especially spawn and echo.
2. Extend the passing bounded four-slot HTTP/WebSocket path with longer soaks
   and more dependency stacks, retaining admission/cancellation bounds,
   responsive health checks, clean shutdown and the compiler/XS gates.
3. Address general Perl I/O handoff and XS/compiler callback/reentry policy.
   Passing one dependency stack cannot establish general CPAN compatibility.
   Keep the passing full standard noninteractive upstream suite as a regression
   gate; it does not establish general concurrent CPAN compatibility.
4. Track static deployment as independent work; it need not wait for every
   parallel-language audit. Million-live-task and broader core-count scaling
   checks also remain explicit acceptance work.

### Matched performance checkpoint (2026-10-29)

The matched-stock harness at `06703df` ran five interleaved samples of each
variant, eight jobs per sample and 500,000 integer iterations per job. It uses
Perl's implicit `$_` loop variable, modulo and addition, with no explicit yields.
Both interpreters are Perl 5.42.2, GCC 14.2.1, `-O2`, with matching compiler/link
flags, multiplicity, op-sharing and 64-bit settings. The host is the same Ryzen
7 PRO 4750U. All 200 job results matched the independent reference.

| Execution mode | Median work wall time | Slowdown vs stock | Speedup vs Wump one slot |
| --- | --- | --- | --- |
| Stock Perl | 0.124182 s | 1.00x | n/a |
| Ordinary fork, Wump disabled | 1.040807 s | 8.38x | n/a |
| Wump, one slot | 4.350042 s | 35.03x | 1.00x |
| Wump, two slots | 5.564762 s | 44.81x | 0.78x |
| Wump, four slots | 6.550921 s | 52.75x | 0.66x |

This workload misses both the close-to-stock and near-linear-scaling goals.
The Unicode backend's earlier multi-slot gains remain valid for that workload;
they do not generalize to this scalar/default-variable loop. These measurements
also expose substantial fork overhead without opting into Wump. They are local
observations, not a general slowdown estimate for all Perl applications.
[Raw samples and summaries](bench/perl-stock-baseline.jsonl) retain exact source
identity, clean-tree status, configuration, CPU time and process timing.

Five fresh native benchmark comparisons at the same source revision used
100,000 iterations and Go 1.27.3 with nodwarf5. Ratios below divide median Wump
wall time by median Go wall time for each identical work size; lower is faster.

| Runtime case | One worker, Wump/Go | Four workers, Wump/Go |
| --- | --- | --- |
| Spawn/completion | 6.44x | 13.03x |
| Voluntary yield | 3.19x | 1.08x |
| Unbuffered round trip | 2.56x | 1.48x |
| Buffered MPMC | 1.45x | 1.16x |
| Ready channel selection | 1.46x | 1.30x |
| Timer sleep | 0.89x | 0.61x |
| Socketpair echo | 9.42x | 7.53x |
| Explicit blocking handoff | 0.09x | 0.97x |
| Native CPU loop | 0.97x | 0.97x |

Spawn, echo and some single-worker cases miss the 2x target. Spawn uses batches
of at most 1024 tasks, so these runs do not validate a million live acts.
Echo measures a socketpair, not TCP. The blocking test uses different runtime
handoff policies and is not a general syscall-cost comparison.
The native CPU row does not assess the design's Perl-versus-Go per-core
compute range; that needs the same algorithm implemented in both languages.
[Raw native samples](bench/design-runtime.csv) and the
[machine/toolchain record](bench/design-machine.json) preserve the evidence.

Separate flat perf profiles used one million iterations per job, eight jobs,
`cycles:u` at 199 Hz and no lost samples. Task-state selection accounts for
about 18% of samples in the ordinary fork and 25% with one Wump slot. Arithmetic
wrappers and metadata operations are also prominent; the four-slot profile
shows about 17% in pthread_mutex_lock. This supports investigating state-access
cost and tracking/synchronization of private operations, including the implicit
loop variable, before making broader scaling claims. It does not establish
which lock or optimization accounts for the full slowdown.
[Named user-symbol profile rows](bench/design-profiles.csv) include entries
at or above 1% and omit unresolved/kernel addresses; percentages retain the
full capture denominator and do not sum to 100. Profiled runs are separate
from the benchmark timings.

### Ordinary execution checkpoint (2026-10-30)

Fresh matched-stock runs compare clean `7a16547` with clean `607927f`, using
five interleaved samples per variant, eight jobs and 500,000 integer iterations
per job. Both builds retain the same Perl 5.42.2, GCC 14.2.1, `-O2`, compiler
and linker flags, multiplicity, op-sharing and 64-bit settings. The host is the
same Ryzen 7 PRO 4750U. Validation jobs were stopped during timing and profiling.
All 400 job results across the two captures matched the independent reference.

| Execution mode | Before median work time | After median work time | After / stock time |
| --- | --- | --- | --- |
| Stock Perl control | 0.126475 s | 0.127591 s | 1.00x |
| Ordinary fork, Wump disabled | 1.033105 s | 0.117151 s | 0.92x |
| Wump, one slot | 4.471900 s | 3.192382 s | 25.02x |
| Wump, two slots | 5.658095 s | 5.202783 s | 40.78x |
| Wump, four slots | 6.455071 s | 6.303846 s | 49.41x |

Ordinary execution is 8.8x faster than the previous fork on this workload,
and about 8% less time than its stock control. The inactive path bypasses task
and allocator selection, uses native opcode bodies with direct root lvalues,
and inlines common dispatch and numeric stores. It retains native validation,
coercion, exceptions, custom opcode hooks and atomic reference counts.
The sticky activation flag and migration-safe TLS loads are described in
section 5.1. Acts still share one interpreter; no interpreter cloning was added.

This removes the ordinary-fork regression on this particular loop. It does
not establish parity across Perl applications or satisfy the active-Wump
performance goal. One-slot Wump is 1.40x faster than before but still takes
25x stock time. Two and four slots remain slower than one, so near-linear
scaling is still unmet. The earlier native/Go measurements are unchanged.

[Before samples](bench/perl-ordinary-before.jsonl),
[after samples](bench/perl-ordinary-after.jsonl), and the
[machine and validation record](bench/ordinary-machine.json) retain exact
revisions, clean-tree status, compiler configuration and binary hashes.

Separate, non-sanitized profiles use `cycles:u` at 199 Hz, with no lost samples.
The ordinary profile uses ten million iterations per job; the one/four-slot
profiles use one million. Ordinary bodies now inline into the runloop, so its
99% flat-profile share includes their native arithmetic and iteration work.
With one slot, mutation admission accounts for about 5%, operand preparation
4%, registry lookup 4% and pthread mutex locking 4%. Four-slot mutex locking
accounts for about 16%. These observations support targeting shared-scalar
captures, temporary allocation and metadata contention next; they do not prove
which individual lock or operation accounts for the remaining slowdown.
[Named profile rows](bench/ordinary-profiles.csv) aggregate equal symbol names
and retain rows at or above 1%, without renormalizing away unresolved samples.

Full project suites pass under GCC, Clang/Clang++ and UBSan. The selected
upstream suite passes 172 scripts and 548,693 checks; the benchmark harness
passes 93 checks. The context change passed Memcheck across 31 Perl suites,
28 native fixtures and interpreter entry. The final inlining change also
passed the ordinary callback/representation suite and five upstream numeric
suites (1,512 checks) under Memcheck. Both use full teardown and leak/origin
checks. Regressions cover selector bypass, first activation during callbacks,
stack growth, custom opcode hooks, numeric representation changes, destructor
reentry and exceptions. A clone-allocation regression fails before the flag
initialization fix and passes afterward, including under Memcheck.

Focused TSan context/allocator, parallel Perl and native fixture checks pass,
including the deliberate-race controls. The full TSan target still fails on
the existing `threads.pm` clone race in `PL_veto_switch_non_tTHX_context`;
the suites after that failure were run separately and pass. The failure remains
visible and unsuppressed. The full upstream suite and the previously blocked
full MSan build remain outstanding.

### State-access checkpoint (2026-10-29)

An earlier performance checkpoint used five runs per slot count, eight
jobs, twenty analysis passes and four worker acts, with the same 128-line
Unicode fixture. All 240 jobs across the before/after samples matched the
reference. On the local Ryzen 7 PRO 4750U (16 logical CPUs), GCC 14.2.1 build,
the median wall times were:

| Execution slots | Before (`020c29b`) | After (`dad7aa3`) |
| --- | --- | --- |
| 1 | 1.122 s | 0.717 s |
| 2 | 0.996 s | 0.855 s |
| 4 | 1.004 s | 0.917 s |

The change replaces repeated current-act lookups within each interpreter-field
expression with one lookup. In separate four-slot `perf` samples, the selector's
share fell from 16.87% to 5.63%; mutex and mutation/borrow paths remain prominent.
These are local observations, not portable performance guarantees. Every slot
count became faster, but the optimized one-slot batch is fastest: absolute
throughput improved without meeting the scaling goal.

[Recorded summaries](bench/mojo-state-access.csv) identify both source revisions
and workload settings. Reproduce the job measurements with
`perl bench/mojo-cpu.pl PRIVATE_PERL --runs 5 --jobs 8 --passes 20 --workers 4`.
These measurements exclude HTTP and reactor work.

### Owned-value metadata checkpoint (2026-10-29)

The next set reduces mutex traffic without treating an unmarked head as proof
of exclusive ownership. A 128 KiB atomic membership filter bypasses registry
locks only for negative probes. Bits are published before registry insertion
and never cleared: failed publication, address reuse and saturation produce
conservative false positives, which still use the authoritative registry.
Repeated publication checks the completed graph marker and foreign writers
before skipping the graph walk. Native registration alone is insufficient.

TSan exposed two additional shared-head writes during this work. Cold overload
cache flags now use metadata guards. Publication moves mortal references into
private RV holders before escape, and later mortalization uses the same private
ownership scheme. Cleanup preserves reference counts and temporary lifetime
without clearing TEMP on a head another act is using. This retains one shared
interpreter; each act has private execution state, not another interpreter.

Five clean-source runs per slot count, with the same hardware, compiler and
workload as above, produced these median wall times:

| Execution slots | Before (`3ac453a`) | After (`12d7e3b`) | After speedup over one slot |
| --- | --- | --- | --- |
| 1 | 0.710 s | 0.670 s | 1.00x |
| 2 | 0.837 s | 0.533 s | 1.26x |
| 4 | 0.942 s | 0.540 s | 1.24x |

All 240 jobs across the before/after samples matched the reference. The
[recorded summaries](bench/mojo-owned-values.csv) include the exact revisions
and workload settings. This meets the first repeatable multi-slot backend gain
checkpoint; four slots still do not improve on two, and near-linear scaling
remains open. These measurements exclude HTTP and reactor work.

The normal Perl tests, selected upstream suite (172 scripts and 548,693
assertions), parallel TSan, ASan with leak detection, Valgrind parallel/native
checks and fresh-source patcher checks pass. New regressions cover zero-lock
untracked probes, address reuse, incomplete native publication, writer
conflicts, temporary ownership, yielding overloads and path scalar boundaries.

The dashboard parses command-line options in CHECK before scheduler startup.
Audited native cwd readers and plain-scalar path canonicalizers advance its
parallel startup, with concurrent, failure/recovery and unsupported-input
coverage. Live one-slot HTTP/WebSocket acceptance still passes all 48 checks.
At this checkpoint, four-slot startup stopped at File::Spec::Unix::_fn_catfile,
whose module-context constants and joining paths needed a separate audit. The runtime
compiler and unaudited XS gates remain in force. The next network checkpoint
is the live dashboard test passing on four slots under an explicit dependency
and compilation policy. Broader magic/weak/object audits and packaging remain
separate work.

### Native dispatch checkpoint (2026-10-29)

Functional Unix path joining now snapshots input heads and uses private join
constants. It retains reference arguments while overloads run without capture
guards, preserves native string-coercion order and repeated calls, and refreshes
the XS stack pointer after coercion. Regressions compare compile-time native
results with one/two/four-slot execution, including empty, undefined, numeric,
boolean, Unicode, embedded-NUL, blessed-scalar and reference inputs, yielding
and throwing overloads, stack growth, tied-input rejection and recovery.
An overload can expose its actual argument RV through a reference to $_[0].
Reference snapshots are therefore published and mutation-claimed before any
coercion callback, with claims released after the native call or on unwind.
An adversarial test verifies that an escaped alias rejects a conflicting read
during conversion and becomes readable after the call returns. No OS mutex is
held across overload execution or scheduling.

The next-method audit exposed a missing call-entry path: goto &sub unrolls
cx_pushsub and bypassed ordinary bridge preparation. Tail calls now prepare
act-local pads and enforce the XS admission gate before unwinding the donor
frame. Before the fix, concurrent tail calls changed arguments or crashed;
unaudited native tail calls also executed. The new tests cover those failures
and audited native tail calls. First-publication head reads are synchronized
in reference generation and tail dispatch. Native temporary sorting/freeing
also avoids writing flags on interpreter-wide immortal values.

The audited mro::_nextcan entry validates and snapshots inputs before its
metadata guard, serializes cold/positive/negative cache lookup, publishes
returned CVs and C3 cache graphs, and releases the guard on returns and
exceptions before the selected Perl method can run. Its reference constructor
does not clear TEMP on shared CVs. Native class-cache invalidation uses the
same metadata synchronization. Tests cover diamond inheritance, next::method,
next::can, maybe::next::method, absent methods, invalid context/arguments,
single-actor inheritance/method updates, guard recovery and publication of
returned methods. General concurrent namespace and inheritance mutation still
requires a broader audit.

UNIVERSAL::can now snapshots plain receiver and method heads, converts method
names before locking, synchronizes capability caches, and publishes returned
CVs without rewriting their TEMP flags. One/two/four-slot tests compare native
lookup results and cover cold/positive/negative caches, inheritance/method
invalidation, Unicode/NUL/numeric inputs, glob references, invalid arguments,
yielding/throwing warning hooks with stack growth, guard recovery, and native
admission when calling a returned XS method. The focused upstream dispatch
run passes 81 scripts and 1,421 checks; project Perl and one-slot Mojo suites
also pass, including all 48 live HTTP/WebSocket checks.

The dashboard now completes option parsing, application/plugin setup, reactor
selection and listener bootstrap in CHECK before execution slots start.
Compile-only validation does not bind a listener. Bare native qr patterns use
Perl's existing clone path without entering the compiler; temporary ownership
survives subject magic, exceptions, stack growth and reentrant matches. `/o`
retains its first pattern. The source patcher replaces earlier generated gates
as well as handling fresh trees. String patterns, overloads, custom engines and
embedded regex code remain rejected. Named-capture FETCH/EXISTS/SCALAR queries
snapshot inputs and use act-local match state; mutations remain read-only and
iterator entries remain gated.

Numeric Socket::getnameinfo snapshots byte addresses and integer flags, checks
IPv4/IPv6 sockaddr sizes, and rejects requests that could invoke name/service
resolution. utf8::is_utf8 snapshots its flag without invoking magic. Four-slot
dashboard startup now reaches the unaudited Encode::utf8::encode entry;
listener destruction also reaches an unsupported dynamic regex. Encoding,
cleanup and the remaining dependency audits still precede live four-slot
HTTP acceptance. The one-slot HTTP/WebSocket baseline remains the network
acceptance target until those gates are cleared.

The expanded socket stress test exposed a first-publication race: builtin
alias classification read a package scalar's head while another act upgraded
it to attach publication magic. Classification now shares the publication
mutex, and reads signal-key caches without coercion or callbacks. Lookup skips
classification entirely when the act has no localized bindings. A focused
stress case combines cold package scalars with an active builtin localization;
TSan remains required for this path as well as the native socket operation.
It also exposed a named-capture tie-classification read racing with overload
cache updates to the stash's head flags. Tie classification now shares that
metadata lock and releases it before creating the act-local capture hash.

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
   - Implemented in the bridge: `use Wump` activates interpreter
     entry, top-level code is the main act, and the `run` wrapper is removed.
     Wait groups use explicit counters with functional and object calls;
     `scope` is removed. These are still module functions; core feature syntax
     remain open. The experimental multi-P bridge uses one shared interpreter,
     with per-act execution state and per-slot allocator caches.
   - Automatic safe-point scheduling, executor allocator caches, atomic shared
     keys/refcounts, graph publication, scalar read claims, deferred storage
     reclamation, and the listed scalar write destinations are implemented.
     Native tests execute actual scalar opcodes with multiple executors. The
     listed binary arithmetic/comparison entries now snapshot plain published
     inputs before raw cache reads; native contention tests do not hold an
     external read claim around those opcode calls. Ordinary shared element
     read-only and existing writable loads in aelemfast/aelem/helem/multideref
     retain the original SV head under a container claim, then release that
     claim before later operand use.
     Native readers retain loaded elements across container deletion/clearing;
     Perl regressions check alias identity, yielding callbacks and teardown.
     Writable call arguments preserve aliases across yields and slot deletion;
     missing lvalues are created and retained under container writers, while
     local views retain their existing paths. Deferred delegates guard their
     own fields and container through resolution, retain resolved targets
     before releasing old owners, and commit fields before owner destruction.
     Nonextendible misses release their original array ownership. Publication
     follows owned lvalue targets and skips opaque native tied target pointers.
     Autovivification guards the source and publishes its new referent before
     committing the reference. Perl and C/C++ fixtures cover creation, deferred
     resolution, yields, container clearing, conflict rejection and cleanup.
     The multideref diagnostic cursor belongs to the act. Weak/object
     reference extraction, other direct RV mutation, mixed magic/key paths and
     other aggregate opcodes remain separate gates.
     Ordinary strong scalar and aggregate reference extraction in rv2sv,
     rv2av/rv2hv and multideref retains each referent independently of its source
     RV before releasing exclusion. Native readers continue through replacement;
     Perl tests cover yielding indexes/keys, nested roots and callback cleanup.
     Scalar operands and writable arguments retain their original heads across
     source replacement and yields, including nested references, lvalue returns,
     tied referents and native lvalue delegates. Scalar autovivification retains
     its guarded publication path; reference localization keeps native behavior.
     Native C/C++ callers exercise scalar/aggregate extraction while another
     executor replaces source RVs, with no caller-held read claim. A separate
     scalar capture bypass must expose the missing lifetime reference.
     Rejected weak/object/magic captures leave their native behavior intact.
     Task-private special globs and localization anchors no longer create
     prototype CVs or participate in namespace backreference lists.
     The interpreter bridge now runs the audited worker-pool paths on multiple
     slots. Remaining state gates still limit the preview's supported scope.
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

## Active arithmetic and live Mojo checkpoint (2026-10-30)

Cached nonnegative signed-IV add/modulo operations with an unpublished,
bodyless IV target now execute the original native branch under the metadata
mutex, without heap snapshots or save-stack guards. The eligibility check
excludes overflow, zero divisors, magic, UVs, taint, unsafe signals and RC_STACK.
The proven branch cannot allocate, throw or invoke callbacks; a native fixture
wraps malloc/calloc/realloc and asserts zero allocations while exclusion is
held. Published targets and all other representations retain general guards.
This is a bounded optimization, and the global metadata mutex still limits
parallel scaling.

Already-initialized, non-get-magical references now take vivify_ref's native
no-op branch under a read claim. They gain neither a false writer nor a hidden
strong referent pin. Foreign writers still take the original mutation-conflict
path. Shared object readers and the existing weak/destructor/alias regressions
cover this distinction.

The callback stack-growth stress exposed an unconditional TEMP-flag write in
list repetition. TSan reported both repeat/repeat and repeat/array-assignment
races on the shared literal head. Repetition now leaves already-clear and
published heads untouched while preserving the original argument aliases;
private temporaries keep native cleanup. The failing callback stress remains
in the suite, alongside explicit repeated-argument alias checks.
TSan also caught newRV_inc rewriting the original head in the min/max retainer.
Min/max and native-handle retainers now use private RV heads with atomic
reference increments and leave the retained value's flags untouched.

The Mojo dashboard passes the external 48-check HTTP/WebSocket test on four
execution slots. Daemon preparation completes helper proxy generation, route
regex compilation, UTF-8 alias resolution and listener setup before execution.
It removes only the listener's own MOJO_REUSE export, allowing native listener
cleanup without process ENV writes or runtime regex compilation. The demo
explicitly disables response compression alongside optional JSON XS, DNS,
SOCKS and TLS. No installed Mojo source is modified.

New audited native entries use private scalar snapshots for UTF-8 Encode
methods (CHECK 0/1), functional MD5/SHA/base64, min/max and numeric queries.
CHECK 1 commits consumed input through the original source alias under a
mutation claim; failed conversion unwinds that claim. min/max return the
original selected argument head, including native tie selection. Ancestry
queries synchronize the method caches. Byte downgrade claims the original
scalar and supports native regex-position/UTF-8 cache magic. Poll accepts only
zero timeout and validates native-int descriptor/event pairs before preserving
in/out aliases. Handle mode supports native Unix layer queries and enabling
nonblocking mode, for the reactor's owned handles. General concurrent PerlIO
lifecycle and arbitrary layered handles remain outside this audit.

This advances the integration goal: real requests, bounded CPU jobs and progress
frames share one interpreter across execution slots. It does not establish the
performance goal, native I/O handoff, general XS compatibility, runtime
compilation support, or long-term production soak acceptance.

Fresh matched-stock captures compare clean `fea5e04` with clean `7f856ef`, using
five interleaved samples per mode, eight jobs and 500,000 iterations per job.
Both use the same GCC 14.2.1 / Perl 5.42.2 `-O2` configuration and stock control
on the Ryzen 7 PRO 4750U. Validation and instrumented builds were stopped during
both timing captures. All 400 job results matched the independent reference.

| Execution mode | Before median work time | After median work time | After / stock time |
| --- | --- | --- | --- |
| Stock Perl control | 0.126604 s | 0.126845 s | 1.00x |
| Ordinary fork, Wump disabled | 0.115943 s | 0.119226 s | 0.94x |
| Wump, one slot | 3.186944 s | 1.622000 s | 12.79x |
| Wump, two slots | 5.279942 s | 1.690933 s | 13.33x |
| Wump, four slots | 6.806358 s | 2.392670 s | 18.86x |

The active one/two/four-slot runs are respectively 1.96x, 3.12x and 2.84x faster
than the previous core. Two and four slots still take longer than one; both
stock-relative active overhead and near-linear scaling remain unmet goals.
Ordinary execution remains comparable to its stock control on this one loop.
These measurements do not establish HTTP throughput or general Perl parity.
[Before samples](bench/perl-active-before.jsonl),
[after samples](bench/perl-active-after.jsonl), and the
[machine/validation record](bench/active-machine.json) retain clean revisions,
build configuration, binary hashes and checks.

Validation passes the complete GCC, Clang/C++ and UBSan project suites, focused
TSan and Memcheck cases, and the optional Mojo target. Selected upstream tests
passed 172 scripts / 548,693 checks; an earlier run hit its 240-second cap under
concurrent builds, and the unchanged test selection passed with a 600-second
cap in 194 seconds. Final repeat/numeric tests add four scripts / 80 checks.
The new callback and shared-head stress tests failed under TSan before their
fixes and pass afterward without new suppressions. The existing clone-related
TSan race, full-MSan locale dependency blocker and Helgrind/DRD tool assertions
remain open; this checkpoint does not claim those full-tool gates are green.

The modified libraries also pass their upstream behavior tests: Encode (7,764
checks plus all five piconv CLI checks), MD5 (283), SHA (130), MIME::Base64 (495),
Scalar-List-Utils (2,166) and IO (16,686). Direct module invocations initially
used incorrect core layouts. piconv was rerun with its required blib layout;
MIME::Base64 uses its standalone module harness and IO its PERL_CORE harness.
MD5's file test expects the original MD5.xs checksum, so that test runs against
the pristine verified source fixture while using the patched digest library.
Expected hashes and upstream test assertions were not changed. Full upstream
and fresh ASan coverage were not run for this checkpoint.

## Compatibility and performance gates (2026-10-30)

The complete standard noninteractive upstream Perl harness now passes: 2,919
files and 1,351,382 checks in 451 seconds. `make perl-upstream-full-test` runs
`test_harness_notty`, with four jobs and a configurable 1,800-second cap.
Normal platform, optional and interactive skips stay visible; this does not
claim the separate lengthy Unicode, big-memory or terminal-dependent extras.
No failing test was excluded to obtain this pass.

The first full run found six failing scripts and pathological CPU use in the
XS macro tests. A five-second profile of a stuck macro case attributed 92.25%
of 496 samples to `Perl_wump_memory_check`. That run was interrupted; it was
not a passing baseline. Before any act has activated Wump, implicit namespace
GV stores now retain native Perl behavior. Previously they unnecessarily
published replacement constants/CVs, changed native scalar representation and
incurred publication barriers during ordinary execution. Explicitly published
container owners still propagate new edges before activation. Regressions
cover constant reflection and explicit pre-activation publication; the constant
case fails against the previous binary and passes after the fix.

The remaining upstream failures exposed patch provenance and fixture gaps.
The parser patcher now validates the exact pinned grammar transformation before
updating generated-file source hashes. Actual Bison 3.8.2 regeneration produces
byte-identical parser files. The vendored XS changes have fixed audited SHA-1
fingerprints and upstream customization metadata, and eleven native diagnostics
are documented in perldiag. Unknown grammar and XS edits are rejected rather
than assigned fresh valid hashes. MD5's existing file test hashes the modified
MD5.xs input fixture: its fixed expected digest now describes that exact audited
source, independently checked with host md5sum and Digest::MD5. Test bodies and
assertions remain intact. This supersedes the prior checkpoint's pristine MD5
fixture workaround.

`make perl-perf-test` captures verified timings and compares them with a saved
checkpoint. Its default 10% limit applies separately to median work time and
whole-process time, each normalized by the contemporaneous stock median, for
ordinary execution and one/two/four-slot Wump. It requires complete raw samples,
clean revisions, matching workloads, CPU models and compiler configurations;
58 fixture checks cover rejection paths and regression boundaries. Invalid or
partial evidence cannot produce a pass. This gate prevents checkpoint
regressions; it does not establish the design's performance target.

Quiet captures compare clean `caa3ab7` and `36cdab4`, with the same GCC 14.2.1,
Perl 5.42.2 `-O2` configuration and Ryzen 7 PRO 4750U stock control. Both use five
interleaved samples, eight jobs and 500,000 iterations per job. No validation or
builds ran concurrently; all 400 job results matched the independent reference.

| Mode | Before median work | After median work | After / stock | Change in stock-relative work |
| --- | --- | --- | --- | --- |
| Stock control | 0.129527 s | 0.131583 s | 1.00x | — |
| Ordinary fork | 0.120849 s | 0.121407 s | 0.92x | -1.11% |
| Wump, one slot | 1.670715 s | 1.674508 s | 12.73x | -1.34% |
| Wump, two slots | 1.621207 s | 1.658267 s | 12.60x | +0.69% |
| Wump, four slots | 2.306413 s | 2.228191 s | 16.93x | -4.90% |

All eight work/process comparisons pass against both the historical active
checkpoint and this fresh control. These small changes are not evidence of
scaling improvements. Active overhead and near-linear scaling remain unmet.
[Before samples](bench/perl-compatibility-before.jsonl),
[after samples](bench/perl-compatibility-after.jsonl) and the
[machine/validation record](bench/compatibility-machine.json) preserve identities,
compiler configurations and binary hashes.

The ordinary XS macro case also has
[raw measurements](bench/perl-compatibility-case.jsonl). Stock and the new fork
each verify all 172,283 checks on three runs; median process times are 16.785
and 35.544 seconds respectively, leaving a 2.12x ordinary-execution gap. The
old fork times out at 30 seconds after 11,242 checks; that incomplete run cannot
supply an elapsed-time speedup. Each binary runs the case in its own matching
source tree with native core include paths. The standard integer fixture alone
would have missed this compatibility-related performance problem.

The project and full project ASan suites pass. Focused TSan publication,
parallel, hidden-root, ordinary and native C/C++ read/operand checks pass with
negative controls and no new suppressions. The optional Mojo target passes,
including the 54 CLI checks, service checks and 48 live HTTP/WebSocket checks
each on one/four slots. Parser regeneration, patcher idempotence/legacy upgrade
and provenance rejection checks pass. Earlier Clang, UBSan and Memcheck results
remain the evidence for those configurations; they were not repeated here.
Full TSan's clone race, full MSan's locale dependencies and the Helgrind/DRD
tool assertions remain open. The next integration priorities are general Perl
I/O handoff, safe XS/compiler callback and reentry policy, broader application
acceptance and deployment tooling, alongside continued overhead reduction.

## Active dispatch and private numeric checkpoint (2026-10-30)

The active dispatcher now inlines ten common opcode bodies generated from the
same patched native sources. Its C invocation retains the owning act pointer
and main/root selection across callbacks and migration. It preserves custom
ppaddr hooks, the 256-op checkpoint cadence, signal checks and the existing
parallel compiler gate. Header inline helpers and other opcodes still select
context dynamically, and allocator lookup always follows the current executor.

Bounded nonnegative cached-IV add/modulo operations now store the result under
the existing metadata exclusion without reentering the general opcode body.
The private target may have IV, PVIV or PVNV storage. A diagnostic link wrapper
showed that the reduction accumulator actually uses PVNV; the former IV-only
eligibility rejected that common case on every addition. The direct store uses
native SvIOK_only/SvIV_set behavior, clearing stale numeric/string/UTF-8 cache
flags before replacing the non-RC stack operands. Overflow, zero divisors,
negative/unsigned operands, taint, unsafe signals, RC_STACK, published targets,
magic, COW and offset PVs retain general handling. The metadata mutex remains
held through each admitted operation, preserving publication exclusion.

Native C/C++ fixtures compare 627 boundary/alias cases against the original
native bodies, including stale PV/NV/UTF-8 caches, separate targets, compound
assignment and aliases to either/both inputs. They retain the zero-allocation
check inside numeric exclusion and concurrent writer/read stress. Added tests
cover COW, offset-PV, UV and existing published-target fallback. The PVIV/PVNV
admission assertion failed before expansion and passes after it. The first
COW fixture relied on automatic copying to create COW, which this fork did not
do; deterministic native shared-HEK storage fixes that setup, and the corrected
cases pass under normal, ASan and TSan builds. Active dispatch tests exercise
main and spawned acts, custom constant hooks, stack-growing yielding overloads,
exception recovery and local state on one/two/four slots.

Quiet five-run captures compare clean `8027355` and `96d8af0`, with the same
GCC 14.2.1 / Perl 5.42.2 `-O2` configuration and Ryzen 7 PRO 4750U stock control.
Eight jobs each execute 500,000 iterations. No validation/builds from this task
run concurrently with timing; all 400 job results verify independently.

| Mode | Before median work | After median work | After / stock | Change in stock-relative work |
| --- | --- | --- | --- | --- |
| Stock control | 0.124485 s | 0.126615 s | 1.00x | — |
| Ordinary fork | 0.116851 s | 0.115588 s | 0.91x | -2.75% |
| Wump, one slot | 1.624541 s | 0.690592 s | 5.45x | -58.21% |
| Wump, two slots | 1.589867 s | 1.057953 s | 8.36x | -34.58% |
| Wump, four slots | 2.354502 s | 1.112275 s | 8.78x | -53.55% |

The one-slot elapsed work improvement is 2.35x; the stock-normalized ratio
improves by 2.39x. Both work and whole-process comparisons pass against the
historical active checkpoint and this fresh control. The default 10% gate now
uses the improved after capture; an explicit negative check rejects the old
active timings against it. This is progress toward stock performance, not
stock parity or parallel scaling. More slots still cost time on this workload.
[Before](bench/perl-dispatch-before.jsonl),
[after](bench/perl-dispatch-after.jsonl), and the
[machine/validation record](bench/dispatch-machine.json) preserve configurations,
clean source identities and measured binary hashes.

The existing Unicode job service also has five-run
[before](bench/perl-dispatch-mojo-before.jsonl)/[after](bench/perl-dispatch-mojo-after.jsonl)
captures: eight jobs, twenty passes, four coroutine workers, with all 240 jobs
verified. Median one/two/four-slot times change from 0.506/0.482/0.609 seconds
to 0.483/0.468/0.565 seconds, improvements of about 5%/3%/7%. These smaller
changes are workload-specific and have no matched stock application control;
they do not establish HTTP throughput or broad Perl parity.

Post-capture cycle profiles have 846 one-slot and 4,407 four-slot samples with
zero reported losses. On one slot, the active dispatcher, numeric admission,
global-scalar lookup and task selector remain visible. Named pthread_mutex_lock
samples rise from 3.03% on one slot to 15.98% on four. Many kernel samples remain
unresolved, so they are not attributed to a particular syscall. The profiles
and worsening multi-slot times identify shared metadata exclusion as a major
remaining scaling concern. Safe private-value ownership/admission and cheaper
state/global lookups are the next optimization targets; weakening publication
or reader safety is not an acceptable shortcut.

Final validation passes the complete project suite, full project ASan suite
plus the latest native operand cases, focused TSan ordinary/active/preemption/
parallel/hidden-root/publication/operand checks and C/C++ negative controls,
and the optional Mojo target including live one/four-slot HTTP/WebSocket tests.
Clang compiles the generated active unit with undefined/float-divide-by-zero
instrumentation; active dispatch and preemption tests pass with that unit linked
over the normal core. This is targeted UBSan coverage, not a full UBSan build.
The final standard noninteractive upstream run passes 2,919 files / 1,351,345
checks in 340 seconds, without added exclusions. Patcher idempotence and legacy
numeric-entry upgrades pass. Prior full TSan/MSan and Helgrind/DRD blockers
remain open; full Clang/UBSan project and Memcheck were not repeated here.

## Numeric admission and stock comparison (2026-10-31)

Independent bounded-IV add/modulo operations now announce short reader regions
in aligned executor slots. Metadata writers close the gate and drain those
announcements before publication, writer admission, node removal or reclamation.
The admission predicates and no-allocation/no-callback contract remain in force.
Native recursive metadata regions and registration OOM retain the mutex path.
Slots become dormant when their executor returns to metadata writes; two eligible
operations without intervening writes warm the next arithmetic burst. Slot
allocations survive dormancy and are freed when executor allocators merge.

The first clean attempt (`7e37630`) made numeric work scale but regressed the
Unicode application by 54%/78% on two/four slots. It was rejected. Its
[before](bench/perl-admission-rejected-mojo-before.jsonl)/
[after](bench/perl-admission-rejected-mojo-after.jsonl) samples remain available.
Registry-only queries, reader/pin counters, completed writer releases and no-op
collection now retain physical registry serialization without fencing unrelated
numeric operations. Actual SV/publication writers still drain readers. Dormant
slots and cheaper native metadata-depth bookkeeping bound the remaining cost.

Two correctness regressions also have fail-before tests. A published target is
rejected from registry state before reading its head; an inaccessible sentinel
page crashed before moving that check. A writer's scalar conversion now installs
its original cache: the classifier tested the impossible shared result 2 instead
of the API's shared result 1. C/C++ tests verify cached conversion and explicit
snapshots inside the claim. Native protocol coverage checks simultaneous readers,
writer exclusion until both leave, closed-gate retry without mutex convoying,
read-only queries/pin bookkeeping beside readers, recursive/nested interpreters,
OOM fallback, dormant-slot reuse and complete teardown. Omitting one announcement
admits a writer early and must abort with the expected negative-control message.
ASan exposed a fixture setup race that invalidated warmup; an explicit setup
barrier fixes the fixture without changing its admission assertions.

Quiet five-run captures compare clean `b6e981e` and `84fd96a`, using matched
GCC 14.2.1 / Perl 5.42.2 `-O2` builds on the same Ryzen 7 PRO 4750U. Eight jobs
each run 500,000 iterations; all 400 job results verify. No task builds or
validation run concurrently with timing.

| Mode | Before median work | After median work | After / stock | Change in stock-relative work |
| --- | --- | --- | --- | --- |
| Stock control | 0.122710 s | 0.123257 s | 1.00x | — |
| Ordinary fork | 0.114076 s | 0.113600 s | 0.92x | -0.86% |
| Wump, one slot | 0.687588 s | 0.600582 s | 4.87x | -13.04% |
| Wump, two slots | 1.025290 s | 0.308694 s | 2.50x | -70.03% |
| Wump, four slots | 1.067141 s | 0.169462 s | 1.37x | -84.19% |

All eight work/process comparisons pass against both the previous recorded
checkpoint and this fresh control. The default integer gate now uses the
improved capture; comparing the old timings against it fails all six active
checks. [Before](bench/perl-admission-before.jsonl),
[after](bench/perl-admission-after.jsonl) and the
[machine/validation record](bench/admission-machine.json) preserve source states,
compiler configurations and exact binary hashes.

Optional eight-slot captures retain all standard controls and rotate six modes
over seven runs. They require complete eight-slot evidence on both sides of a
regression comparison; advertising eight slots without their samples fails.
These two work sizes beat sequential stock on this integer fixture:

| Iterations per job | Stock work | Eight-slot work | Stock whole process | Eight-slot whole process |
| --- | --- | --- | --- | --- |
| 500,000 | 0.125438 s | 0.099220 s | 0.139043 s | 0.122760 s |
| 2,000,000 | 0.499430 s | 0.393886 s | 0.511212 s | 0.411951 s |

The longer case uses about 21% less work time and 19% less whole-process time.
Eight slots achieve about 6.1x scaling over one slot on that case. This is one
parallel workload using eight execution slots against sequential stock; it does
not establish broad Perl parity, low single-slot overhead or the Go runtime
target. [Standard-length](bench/perl-admission-eight.jsonl) and
[longer](bench/perl-admission-eight-long.jsonl) raw samples retain every control.

The Unicode service's five-run one/two/four-slot work medians change from
0.481/0.460/0.538 seconds to 0.480/0.470/0.516 seconds, or -0.15%/+2.05%/-4.05%.
All six work/process comparisons pass the 10% budget, with 240 jobs verified.
[Before](bench/perl-admission-mojo-before.jsonl)/
[after](bench/perl-admission-mojo-after.jsonl) are application comparisons with no
matched stock application control or HTTP-throughput claim. The archived
comparison helper also rejects the first attempt's application regressions.

Cycle profiles taken afterward have zero reported losses. Across one/four/eight
slots the active dispatcher accounts for about 36–40%, numeric admission
16–20%, global-scalar lookup 13–17%, and task selection 5–8% of samples. Named
pthread mutex entries no longer reach the 1% reporting threshold on this numeric
fixture. Application metadata contention remains a separate concern. State and
global lookup overhead are the next measured numeric targets; automatic Perl
I/O handoff, compiler/callback policy, remaining shared-cache/XS audits and
broader application acceptance remain integration priorities.

The complete runtime/Perl project suites, full project ASan rerun, optional Mojo
target (including 48 live HTTP/WebSocket checks each on one/four slots), 107
benchmark-runner and 71 gate checks pass. Eight repeated native protocol runs
pass with their negative controls. Targeted Clang undefined/float-divide-by-zero
instrumentation covers the metadata unit and native protocol fixture over the
normal core; this is not full-core UBSan coverage. Native Memcheck reports zero
errors and no leaked blocks. The complete standard noninteractive upstream
harness passes 2,919 files / 1,351,237 checks in 374 seconds, with no added
exclusions. Patcher idempotence, legacy upgrade and provenance checks pass.

Broad TSan attempts all 35 Perl suites and ten native drivers. All native drivers
and 34 suites pass, including numeric exclusion and C/C++ reader/writer stress.
The `keys` suite retains the same `S_ithread_clear`/`S_ithread_run` race on
`PL_veto_switch_non_tTHX_context`, reproduced on the previous `b6e981e` binary.
No suppression or exclusion hides it. Wump acts do not use Perl ithreads. Full
MSan locale dependencies and Helgrind/DRD internal assertions remain open.
