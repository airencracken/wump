# Perl integration reference

Commands run from the repository root.

## Running Perl tasks

The Perl integration targets Perl 5.42.2, matching the installed Perl
and the design's 5.42 base. The private fork can run Perl closures as runtime
tasks, send scalar values and references through channels, yield, and sleep.
Set `WUMPPROCS=4` to execute supported Perl workloads on four slots. The
default is one slot; accepted values are integers from 1 through 256.
All acts share one interpreter, compiled code, namespaces, and shared values.
Each act has separate execution state; spawning an act never creates or clones
an interpreter. Executor allocation caches belong to slots, not acts.
`Wump::execution_slots()` reports the actual slot count from a running act,
independently of later environment changes or the number of spawned workers.

The optional [Mojolicious job dashboard](../examples/mojo/README.md) exercises
HTTP, WebSocket progress, bounded work queues, cancellation, and shutdown while
Wump coroutines perform CPU work. Run `make perl-mojo-example` after installing
its optional dependency, or `make perl-mojo-test` for service and TCP load tests
on one and four execution slots. Set `WUMPPROCS=4` for the parallel demo.
The build does not install or replace system Perl.

```sh
make perl-fetch                 # downloads, verifies SHA512/size, and unpacks
make perl-build                 # task-aware MULTIPLICITY + USE_ITHREADS build
make perl-example               # Perl tasks return 1, 4, 9, 16
make perl-waitgroup-example     # Functional and object wait groups
make perl-regex-example         # yielding tasks retain separate regex captures
make perl-local-example         # spawned tasks inherit separate local bindings
make perl-elements-example      # tasks localize individual shared hash elements
make perl-pocket-example        # native pocket keyword keeps a binding in this act
make perl-separators-example    # readline/chomp use each act's record separator
make perl-test                  # task behavior, failures, shutdown
make perl-parallel-test         # one interpreter, worker pools on 1/2/4 slots
make perl-parallel-tsan         # whole-core parallel and allocator race checks
make perl-parallel-memcheck     # parallel pool and repeated-runtime teardown
make perl-parallel-bench        # verified string workers on 1/2/4 slots
make perl-mojo-cpu-test         # dashboard CPU backend on 1/2/4 slots
make perl-mojo-cpu-bench        # repeated verified Unicode job batches
make perl-upstream-test         # upstream regex, aggregate and interpreter regressions
make perl-upstream-full-test    # complete upstream noninteractive core/library/extension suite
make perl-parser-test           # verify generated parser with Bison 3.8.2
make perl-memcheck              # task suite with registered C stacks and full Perl teardown
make perl-asan                  # separate instrumented Perl, runtime, and XS fixtures
make perl-lsan                  # same instrumented suites with leak checks and full teardown
make perl-source-test           # offline source acquisition failure tests
make perl-allocator-test        # native allocation and cross-executor final frees
make perl-allocator-tsan        # instrument the entire private Perl and fixture
make perl-reads-test            # plain shared-scalar conversions and copies
make perl-reads-tsan            # eight readers against an instrumented private Perl
make perl-writes-test           # scalar opcode/API writes, callbacks and native contention
make perl-writes-tsan           # instrumented opcode tests and allocator race control
make perl-operands-test         # opcode operand snapshots and native contention
make perl-operands-tsan         # whole-core concurrent opcode reads/writes
make perl-operands-memcheck     # operand callbacks, unwind, and native teardown
make perl-loads-test            # shared elements retained across container writes
make perl-loads-tsan            # whole-core concurrent container-to-stack loads
make perl-loads-memcheck        # element pins, callbacks, and task teardown
make perl-references-test       # scalar/aggregate referents survive RV replacement
make perl-references-tsan       # whole-core dereference handoff and writer checks
make perl-references-memcheck   # referent pins, rejected paths, and callback cleanup
make perl-materialization-test # created/deferred lvalues and autovivification
make perl-materialization-tsan # whole-core creation and ownership handoffs
make perl-materialization-memcheck # deferred owners, cell lifetimes, and cleanup
make perl-memory-test           # borrowed storage, concurrent publication/writes, migration
make perl-memory-tsan           # whole-core reclamation stress and deliberate-race control
```

For an existing release archive, use
`make perl-build PERL_TARBALL=/path/to/perl-5.42.2.tar.xz`.
`PERL_JOBS=4` controls build parallelism. Run the Perl targets serially;
concurrent invocations against the same generated tree are unsupported.
Source, configuration, and build
outputs stay under `build/perl/`; the release archive is pinned by
[perl/upstream.lock](../perl/upstream.lock). Existing unrecognized source trees
are preserved and rejected. `make clean` removes these private build outputs
along with the runtime build outputs, so keep editable fork changes in
repository patches rather than only in the generated source tree.

### Execution state and dispatch

The prototype can run acts concurrently on several execution slots, with
separate stacks, pads, exception state, regex state, and execution phase.
The active-task selector is thread-local and filtered by
interpreter identity, so native threads can select independent task state
against one interpreter while other interpreter contexts retain their root
state. `make perl-task-context-test` checks 200,000 concurrent state updates
without executing Perl opcodes or allocating Perl values in those threads;
`make perl-task-context-tsan` instruments that fixture with TSan. This is a
state-isolation prerequisite. The parallel acceptance test additionally runs
16 Perl workers through shared channels, scoped locks, nested acts and wait
groups on one, two and four slots. Native diagnostics verify that the acts use
the same interpreter and execute on multiple slots.

The active runloop inlines common native opcode bodies with the task pointer
owned by that C invocation. The pointer remains valid when that same act yields
or migrates; allocator access still selects the current executor dynamically.
Custom opcode addresses retain their original dispatch, and the existing
checkpoint, signal and runtime-compilation checks remain in force. Bounded
cached-IV add/modulo operations update private IV/PVIV/PVNV targets under the
metadata exclusion without entering the general conversion machinery. Shared,
magical, COW, offset-PV and unsupported numeric cases retain their guarded
native paths.

An admitted numeric operation announces itself in an executor-owned slot and
runs alongside other numeric readers. Metadata writers close a shared gate and
wait for those short operations to finish before changing publication or
mutation state. Readers arriving at a closed gate withdraw and retry without
queuing on the writer mutex. Slots are allocated lazily, isolated on separate
64-byte regions, and released when executor allocators merge. Registration
allocation failure and recursive native metadata regions retain mutex admission.
An executor returning to metadata writes unregisters its dormant slot, retaining
the allocation for its next arithmetic burst. Two eligible operations without
intervening metadata writes warm admission; isolated arithmetic keeps the mutex.
Read-only registry probes, pin
bookkeeping and completed mutation-claim releases use the registry mutex without
stopping numeric readers; publication, writer admission and reclamation still
close and drain the gate.
No callbacks, allocation, metadata entry or scheduling occur between numeric
admission and release.

Canonical default, error and regex-code-result scalar cells also have a direct
lookup in the public GV accessor. It selects the main interpreter cell or the
owning act's private cell without a callback. Active
local bindings and effective-glob aliases retain the full accessor, including
regex-cell handling and publication of ordinary package values. Each call
selects its current act without retaining a native TLS address or a cached
result across callbacks or scope changes.

Spawned acts' default, error, and regex-result globs are private storage cells.
They keep their special names without namespace backreferences or unintended
prototype CVs. Localization anchors likewise retain only their target GP;
creating and retiring these cells does not invalidate shared method caches.
Namespace backreference updates and the audited class/method-cache lookups
use short native metadata guards. These guards end before a method body runs;
callbacks cannot schedule while a guard is held. Newly cached class data uses
private temporary reference holders so scope cleanup does not rewrite shared
cache flags. General namespace mutation,
weak-reference updates and other caches still require a concurrency audit.

Tail calls (`goto &sub`) prepare the target's act-local pads and apply the
same XS safety check as ordinary calls before unwinding the donor frame.
The audited `mro::_nextcan` entry serializes next-method cache lookup and
publishes returned CVs, then releases its guard before Perl method execution.
Native reference generation synchronizes head-flag reads with first
publication; temporary cleanup preserves interpreter-wide immortal flags.
`make perl-mro-upstream-test` adds upstream MRO, goto and Unicode goto coverage.

`UNIVERSAL::can` snapshots plain scalar/reference receivers and plain scalar
method names in parallel mode. Method-name conversion and warning hooks run
before the metadata guard; lookup and returned-CV publication share dispatch's
cache synchronization. The guard ends before a returned method executes.
Tied inputs, reference-valued method names and bare globs remain unsupported
in parallel mode; glob references and ordinary blessed references are accepted.

Bare precompiled `qr` patterns from the native regex engine now run in parallel
without invoking the compiler. Match caches and captures remain private to each
act; `/o` keeps its first pattern. Tests cover subject magic that yields, grows
the Perl stack, throws, or reenters the same match operation. Pattern strings,
overloaded patterns, custom engines and embedded regex code remain gated.
Native named-capture FETCH, EXISTS and SCALAR queries are admitted with private
input snapshots; mutation and iterator entries remain gated.

`Socket::getnameinfo` accepts plain packed IPv4/IPv6 addresses with explicitly
numeric host/service flags. Resolver-backed requests and other Socket entries
remain gated. `utf8::is_utf8` reads the flag under metadata synchronization and
rejects magical inputs; it does not admit the other `utf8` helpers.

The functional Unix path join entries use private argument heads and join
constants. Reference arguments retain their original referents while overloads
run outside capture guards; native coercion order and repeated calls are
preserved. Reference snapshots stay mutation-claimed until the native call
returns, so escaped aliases cannot race with conversion-cache writes. These
claims permit scheduling and release on exceptions. Tied inputs and other
unsupported magic remain rejected in parallel
mode. Method variants and the remaining dependency XS still need audits.

### Main entry and task API

`use Wump` enables interpreter-owned scheduling: ordinary top-level Perl runs
as the main act. The interpreter starts and stops the scheduler automatically,
using the configured slot count. `act { ... }` spawns work directly and returns
immediately. The prototype's former `run` wrapper has been removed.

Current prototype example:

```perl
use v5.42;
use Wump;

my $results = chan(2);
for my $number (1..4) {
	act { $results->send($number * $number) };
}
say scalar $results->recv for 1..4;
```

The preview exposes task/channel functions from `Wump` with native core
operations for imported `act`, `chan`, `sleep` and bare `yield`; the design's
complete core feature syntax remains unfinished.
Imported `act { ... }` and `act(sub { ... })` compile to a native creation
opcode after Perl's normal prototype checks. Custom wrappers, qualified
`Wump::act`, ampersand/indirect calls and `no Wump` scopes keep function
dispatch. Closure capture, local snapshots and cleanup share the existing
creation implementation; callback results remain discarded from scalar entry
context. Imported `chan` and `sleep` use the same compiler mechanism, preserving
their prototypes and the qualified/custom-wrapper compatibility paths. Their
native operations share XS validation and lifetime/scheduling helpers; they
do not enter a Perl wrapper or XS call. `act` returns nothing. `chan()` is unbuffered;
`chan(N)` has N slots. `send` copies its scalar, preserving reference identity.
`recv` returns a value in scalar context, or `(value, ok)` in list context;
`ok` is false once a closed channel is drained. `undef` remains a valid message.
`close` wakes waiting tasks; duplicate close and send-after-close throw within
the task. `yield` and `sleep(SECONDS)` schedule cooperatively. Bare `yield` and
`yield()` compile to a native `wumpyield` opcode in `use Wump` scope, entering
the scheduler without a Perl wrapper or XS call. Qualified `Wump::yield()` and
indirect function calls retain the compatibility path. `no Wump` restores
ordinary name parsing; methods and implicitly quoted hash keys keep their
existing meaning. Native yield returns undef in scalar context and an empty
list in list context, preserving surrounding operands across suspension.
These operations require a running task. Compile-time blocks cannot schedule, and importing
Wump at runtime without compile-time activation fails explicitly.

Channel `send`, `recv` and `close` have direct core entries. The interpreter
first performs normal method resolution, including subclasses, `SUPER` and
replacement methods. It recognizes only the three original channel entry
addresses, after the existing XS admission/publication checks, and invokes
their common helpers before Perl wrapper or XS call-frame setup. Method calls
remain `entersub` operations; this is runtime dispatch, not static receiver-type
inference or a new reserved method name. Custom methods retain their bodies.
This path also avoids allocating a private Perl method pad for each new act.

The compatibility XS entries share the same payload copying, reference
publication, registry validation, exceptions and channel lifetime code. Implicit
`@_` forwarding, tail calls, debugger/lvalue handling and refcounted-stack
builds retain the upstream adapter where needed. The tested build uses the
ordinary unrefcounted operand stack; this does not establish general support
for experimental refcounted-stack builds. Older private controls keep their
Perl method wrappers when they load the current module.

### Wait groups

Wait groups track explicitly registered work, as in Go. Functions and methods
operate on the same counter:

```perl
my $wg = waitgroup;                 # or Wump::WaitGroup->new
for my $id (1..8) {
	add $wg, 1;                      # or $wg->add(1)
	act { work($id); done $wg };      # or $wg->done
}
await $wg;                         # or $wg->wait
```

`add` defaults to one and also accepts negative integer deltas; `done`
subtracts one. `await` and `wait` return when the counter is zero, releasing
all waiting acts. Register work before spawning it. A group can be reused
after all previous waits have returned. Negative counters, overflow, and reuse
while previous waiters are returning fail without changing the counter.
Only explicitly registered work participates; lexical blocks and act ancestry
do not add membership. Returning from main still ends the program.

The function is named `await` because Perl's existing `wait` keyword remains
the process-wait builtin. Object calls use `$wg->wait`. `use Wump::WaitGroup`
enables the object interface without exporting functions. There is no
`scope {}` wrapper. See [examples/waitgroup.pl](../examples/waitgroup.pl).

### Exceptions and shutdown

Returning from the main program abandons other tasks. A caught `die` stays within
its task. An uncaught task exception stops the scheduler, prints its task ID and
error, and exits the process with status 2, including inside an outer `eval`.
Full task stack traces are still pending. Deadlock prints a runtime diagnostic
and exits with status 2. Explicit main `exit` preserves its requested status.
INIT and END blocks keep their interpreter ordering; END runs in the main act
before remaining acts are abandoned.

The fork redirects execution state through a task pointer instead of copying
interpreter globals at every switch. Each task owns its Perl stacks, exception
state, default scalar, arguments, and separate pad frames for called subs.
Captured and `state` lexicals retain their shared identity. Stashes and op
trees belong to one interpreter; tasks do not clone interpreters. The main act
borrows the interpreter's original stacks, which remain owned by Perl teardown.
Spawned acts own separate stacks. The design's full
`aTHX`/per-task/per-P/process-global split remains future work.

### Implicit state and regexes

Custom sorts preserve their `$a`/`$b` operands across yields in main and spawned
acts. Linux `$!` and `$^E` use the scheduler's per-act native errno; `$?` has
task-local status storage. Their `local` bindings restore the enclosing value
on return and exception unwind. New acts start with their own error and status
values rather than inheriting those bindings.

Regex match state is task-local. Numbered and named captures, capture offsets,
`/p` values, `$^R`, named-capture hash iterators, match-once flags, and `/o`
caches survive yields without taking another task's results. Runtime `/o`
patterns compile on their first evaluation in each task. Regex code blocks
and substitution replacements can yield; `qr` values retain their captured
lexicals when sent to another task or retained after their creating act exits.
An empty pattern still uses the calling task's previous pattern, and tied
match inputs still receive their normal magic callbacks.
Scalar match-result cells, including numbered captures, `$+`, `$^N`, and `/p`
values, are private to each act as well as its match engine state. Aliased
globs share the act's cell, and `local` retains native capture magic and
read-only behavior. Parallel copies also own their mutable substring search
caches; compiled regex code remains shared.

Instances are created lazily from the compiled pattern. Each PMOP has a unique
identity so a recycled Perl regex-pad offset cannot retrieve an old task's
instance. Tasks own mutable match data and named-capture iteration state;
compiled pattern storage can be retained through Perl's regexp copy support.
Entries for retired regex operations remain cached until the task ends.
Shutdown releases these references and regex callback frames while their Perl
and C stacks are still available. `pos()` remains a property of the scalar
being matched: using one shared string also shares its position.

Parallel Perl additionally needs the remaining shared-value and
pad-pooling changes described in [the design](../DESIGN.md).
Enabling `USE_ITHREADS` prepares Perl's op-sharing infrastructure; it does
not add `threads.pm` compatibility or implement task isolation by itself.

### Dynamic localization

Ordinary package scalar, whole-array, and whole-hash `local` bindings belong
to the calling task. They survive yields, unwind on return or caught exceptions,
and leave the global slots intact. Glob aliases see the same binding; references
taken before localization retain the original value's identity. A spawned task
inherits a snapshot of its parent's visible bindings. Scalar values and aggregate
elements are copied shallowly, so referenced objects remain shared. Parent scope
exit and later assignments do not change the child's inherited slots. Bindings
in compile-time code retain upstream Perl behavior.

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

`local` and `pocket` also support the input record separator `$/` and output
record separator `$\`, including English aliases. Each binding owns both its
Perl value and the cache used by `readline`, `chomp`, and `print`. String,
Unicode, slurp, paragraph, and positive fixed-record-length reference modes
retain their ordinary meanings. Invalid input-separator assignments leave the
previous value and cache intact. Ordinary assignments without a binding remain
global; `local` snapshots propagate to children and `pocket` snapshots are skipped.
Perl's temporary internal separator overrides, such as tied `say`'s newline,
remain within the current act and are excluded from child inheritance.

References to separator cells retain their own cache after scope or task exit.
Writing through a reference to a base cell changes the base setting, while a
reference to a localized cell stays private. This deliberately avoids stock
Perl's interpreter-wide cache behavior for references to localized magic
scalars: an escaped `$\` reference in this fork retains its localized value
instead of consulting the current global output cache.

`local` and `pocket` support `$SIG{__DIE__}`, `$SIG{__WARN__}`, and `$^W`
(including `$English::WARNING`). Hook callbacks and their recursion guards
remain private across yields. Ordinary local hooks/flags are snapshotted at
spawn; pocket bindings are skipped. Native warning generation uses the private
`$^W` cache, while explicit lexical `use warnings`/`no warnings` retain their
usual precedence. Encoding layers can initialize inside acts. PerlIO's temporary
loading hook stays within the current act and is excluded from inheritance.
Hook and warning-cell references retain their private cache after scope exit,
with the same identity rules as separator references. Localization of process
signal handlers, whole `%SIG` localization, and `${^WARNING_BITS}` localization
remain unsupported. Signal handler assignments remain process-wide.

`delete local`, typeglob/reference-alias localization, and localization of other
magic variables (including tied values, `%ENV`, and `$^I`) raise
errors inside tasks. Restricted hashes and symbol-table elements are also rejected.
Plain aggregates must not acquire unsupported magic during a binding's lifetime.
Spawn rejects unsupported magic values inside inherited bindings before invoking any `FETCH`
hooks. Localizing a whole plain aggregate
and then assigning its elements is supported. Symbol-table replacement while a
binding is active is not supported. These limits keep the remaining shared-state
paths explicit while their isolation is developed.

Numbered capture localization (`local $1`, `local ($1, $2)`) preserves the act's
current regex state. `local $^F` restores the act's descriptor inheritance
boundary; child acts inherit its current value (`pocket $^F` is rejected).
`local $.` restores the act's
last-read handle. A new child begins without a last-read handle; line counters
remain properties of their actual filehandles. Sharing a filehandle still
requires coordinating its I/O between acts.
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

Pockets currently support the same package variables, elements and slices
as task-local `local`, with the restrictions described above. Executing `pocket`
requires a running main or spawned act; lexical scalar targets remain invalid, as with
`local`. `no Wump` disables the keyword within its lexical scope. Qualified
names, method names and hash keys retain normal lookup. The keyword is an
experimental part of the private fork, not a stock Perl feature.
`B::Deparse` preserves pocket declarations so recompiling its output keeps
their inheritance policy.

Perl's existing `lock VAR` now acquires an explicit scoped mutex inside acts.
It parks contending acts cooperatively, so the holder can yield while keeping
the lock. References lock their referent; `lock %hash` and a reference to that
hash address the same mutex. Locks are released on scope exit, exception unwind,
and abandoned-task cleanup. Acquisition is not reentrant: locking the same
identity twice in one act raises an error. Locks are not inherited at spawn.
The lock retains its target while holders or waiters exist, then releases it
immediately. Scripts that do not enable Wump keep upstream Perl's lock behavior.
See [examples/safety.pl](../examples/safety.pl), or run `make perl-safety-example`.

The private core now uses atomic SV-head reference counts as a conservative
baseline, including the normal C/C++ reference-count helpers. This currently
adds overhead to owned values too; the proposed owned/shared fast path is
still pending. The native stress fixture exercises eight
OS threads performing 9.6 million increments/decrements on a rooted SV, in
both C and C++, without concurrent allocation or value mutation. Run it with
`make perl-refcount-test`, or `make perl-refcount-tsan` to instrument the native
counter fixture with ThreadSanitizer. C++ XS keeps the original head layout;
direct legacy XS manipulation of the refcount lvalue still needs serialization.

The fork now redirects SV-head and value-body arena caches through an
executor selector, independent of act identity. Each executor has its own
free lists, arena registry, and signed allocation count. A value freed on
another executor goes into that executor's cache; its original arena remains
alive. After all executors stop, their caches and registries merge into the
interpreter for normal global destruction. Values can survive the merge.
The current one-slot bridge uses this path during execution and task cleanup;
ordinary code outside the scheduler retains the root interpreter's caches.

`make perl-allocator-test` runs eight native executors against one interpreter,
allocating and exchanging 131,072 scalar, string, reference, array, and hash values.
It checks distinct live allocations, cross-executor final frees, root-cache
isolation, interpreter identity, cache migration between native threads,
surviving values, cache reuse, and full interpreter teardown. Its private
execution stacks isolate temporary values during container destruction.
`make perl-allocator-tsan` builds a separate interpreter, runtime, and fixture
with TSan throughout, including the allocator's out-of-line C paths.
The target also requires TSan to detect a deliberate shared-cache race inside
`Perl_more_bodies`. `make perl-memcheck` includes the native fixture under
Valgrind with full leak checking.

The shared string-key table now has a mutex per interpreter for lookup,
insertion, resizing and removal. Shared-key retains use atomic counters,
including the C/C++ `share_hek_hek` macro path; nonterminal drops use an atomic
CAS loop. Key bytes and flags stay immutable. Key allocation and warning
callbacks run outside the mutex, so
warning hooks can intern keys, yield, or throw. Oversized keys fail before
locking. Legacy `unsharepvn` now normalizes negative UTF-8 lengths and hashes
the same way as interning, including ASCII and Latin-1 downgrade cases.

Each executor also owns its hash-order randomization state and the allocation
failure flag used during hash growth. Fresh caches snapshot the caller's
randomization state through the internal allocator initializer; no worker
advances the root interpreter's random stream. The native fixture forces
table growth with 8,192 live keys, releases keys on other executors, and
checks ordinary private hashes with shared keys and hash randomization enabled.
The legacy-key regression runs in C and C++. Separate Perl checks cover
throwing/yielding warning hooks and key-table mutex setup in ordinary cloned
interpreters; Wump acts still do not support `threads.pm` integration.

These initial caches allocate new arenas directly; central cache refill
remains future work. The fixture does not run Perl opcodes concurrently,
mutate shared graphs, or execute arbitrary destructors.
Executor arenas require system malloc without Perl's memory-tracking modes;
`use Wump` rejects unsupported tracking builds and `-DD` arena scans before
scheduling starts.

Published plain scalars now use private snapshots when a conversion needs
to compute a representation. This batch covers signed/unsigned integers,
floating-point and truth conversion, computed string buffers, byte/UTF-8
conversion, and scalar copies. Snapshots preserve dual values, private versus
public cache flags, and boolean identity without changing the source's flags,
body, string buffer, or COW count. Numeric and truth macro fast paths take a
short reader claim before inspecting caches. Plain-scalar snapshot capture
holds the same exclusion against writers through its allocating copy.

Core scalar conversion now obtains publication classification and its reader
claim together. A private scalar avoids metadata locking, and a shared scalar
uses one authoritative lookup before its eligibility checks. The proof ends
with the claim; allocating snapshots still establish their own exclusion.
An active writer keeps conversions on its original scalar, and ordinary root
API calls preserve snapshot behavior for explicitly published values.

Computed string buffers survive nested conversions and yields until the
caller's current temporary scope ends. Read frames belong to the current act,
retain the source through callbacks, and unwind on exceptions or abandoned
acts. Undefined-value warnings retain the original variable name. Explicit
mutable-buffer requests, string forcing and UTF-8 upgrades still modify the
original value. Tied values, overloaded references, and other magic retain
their upstream paths and require a separate concurrency audit.

`make perl-reads-test` checks C and C++ conversion/copy behavior and runs eight
native readers through 14,336 read/copy cycles against one interpreter.
Publication finishes before the readers start; sources remain immutable while
the native threads run. `make perl-reads-tsan` instruments the whole private
Perl and also checks the allocator's deliberate-race control. Perl tests cover
warnings, throws, yields, encoding failures, explicit mutators and abandoned
read callbacks; `make perl-memcheck` checks these paths and native readers with
full leak checking. The native suite also runs six readers and two writers
against one scalar through 1,024 IV/UV/NV/PV representation changes and 3,072
numeric/copy/encoding captures. Contending native callers can request a claim
with a contention result and retry; ordinary read APIs throw before accessing
a value owned by another writer.

Published ordinary hashes now keep `each`/`keys`/`values` cursors in the
current act. One act's iteration and resets leave other acts' cursors alone;
publication preserves the parent's progress, and children start with fresh
cursors. Iteration reads raw buckets and records
visited keys without copying values or retaining HE pointers between calls.
Value aliases remain live, and deleting current or upcoming keys within one
act remains supported. Native hash copies also avoid changing the source
cursor. Existing element overlays retain their private-view iteration path.
Adding an element binding starts a fresh private view for that act.

A partial cursor retains its hash until reset, exhaustion or act cleanup.
Reset and exhaustion release that pin after the current operation, using a
private reference so cleanup never writes the source's temporary flag.
Visited-key storage grows with the keys read; collision chains are rescanned,
so heavily colliding buckets can take quadratic work. Tied/restricted hashes,
stashes, and other hash magic retain upstream iteration paths. Legacy XS that
reads or writes cursor fields directly still needs an audit.

The native readers also traverse 265,216 shared hash entries, including long
collision chains, empty/NUL/UTF-8 keys and numeric-valued native clones. They
check unchanged source flags, storage, cursor and randomization state. Perl
checks interleaving, reset contexts, deletions, aliases, weak lifetimes, tied
hooks and abandoned iterators.

Ordinary and encoded cached string reads pin the published scalar's current storage
until the caller's temporary scope ends. Audited scalar mutation APIs detach
the body and PV before writing; old storage remains alive for existing
borrowers. Native array-slot and hash-entry borrowers use the same protocol.
Array storage and hash buckets/HE chains detach without changing live value
identity. Removed elements remain owned by the retired storage until reclamation.
Pins belong to task stacks and survive yields, parking and executor migration.
Byte and UTF-8 macro variants, including `nomg`, `nolen` and `or_null`, use this
capture path. Encoding mismatches convert private snapshots; undefined
`or_null` reads return null without invoking warning hooks. Snapshot-only
captures release their source pins as soon as copying finishes. Their temporary
cleanup tokens remain available for allocation exceptions without adding save
records inside native localization operations.

Graph publication is serialized by a per-interpreter metadata mutex, with
thread-local recursion suppression. Publication completes every reachable
descendant before another publisher can return. Mutation claims are atomic,
owned by acts, nest within one act, and unwind after exceptions or abandonment.
Conflicting writers, publishers and readers using the borrow protocol fail
before accessing guarded storage. No OS mutex remains held while a mutation
invokes Perl callbacks.

A bounded 128 KiB atomic filter lets registry probes for untracked heads
avoid the metadata mutex. A positive result still checks the registry; bits
are never cleared, so rollback and address reuse can only add false positives.
This does not establish exclusive ownership. Repeated publication skips the
graph walk only after checking the completed native marker and active writers.
Published mortal values transfer their temporary references into private RV
holders, preserving statement lifetime without cleanup changing shared TEMP
flags. Cold overload-cache flags use the same metadata synchronization.

`make perl-memory-test` exercises eight native executors, synchronized writes,
cached buffers, array slots, deleted hash entries, COW aliases and migration.
Allocation-failure tests verify that failed retirement preparation leaves live
scalar/array/hash storage unchanged and releases the writer claim. Retirement
uses a conservative interpreter-wide pin count: one long-lived borrower can
delay collection of unrelated retired storage. Cloning requires quiescent pins
and mutation claims; clones rebuild their own metadata registry.

Audited scalar opcodes now enter the mutation protocol before their original
bodies inspect the destination. This covers assignment, prefix/postfix
increment and decrement, arithmetic and bitwise compound assignment, concat
and optimized multiconcat, and recursive chop/chomp. Postfix operations also
guard the result pad. Substring and vector lvalue setters guard their original
referents, including aliases created before another act starts mutating them.
Claims span GET/SET and overload callbacks and unwind after throws or abandoned
acts. The C API coverage includes increment/decrement, UTF-8 encode/decode and
downgrade, scalar replacement, and explicitly mutable numeric conversions.

Core mutation code can install conversion caches while its act owns the
exclusive writer claim. Explicit snapshots remain available during a write;
ordinary external reads still avoid changing source caches. In-place encoding
and chop/chomp request writable buffers so they edit the live scalar rather
than a private read snapshot.

`make perl-writes-test` compares published writes with private-scalar controls,
checks borrowed storage and callback cleanup, and runs C/C++ fixtures with six
readers and two writers performing 4,096 actual opcode mutations. Plain scalar
leaves are registered directly in the native fixture's side registry to reach
fast paths that publication magic would otherwise divert. Bypassing an entry
guard must fail its old-body regression; real Perl tests independently expose
the original opcode's unguarded STORE callback window.

Plain scalar pairs now receive stable operand snapshots before arithmetic,
bitwise, numeric comparison, integer comparison, and string comparison opcodes
inspect cached flags or raw scalar bodies. A short reader claim protects
classification and snapshot capture; no reader exclusion spans warning or
other Perl callbacks. Snapshots retain numeric/string dual values, boolean
identity, encoding and original-variable diagnostics while leaving source
caches unchanged. Repeated references to one source reuse its captured value.
Compound assignment leaves its destination under the existing writer protocol.
Comparison result pads also enter that protocol.

Operand diagnostic frames and retained source heads belong to the act and
unwind on exceptions or abandoned callbacks. Mixed reference, overload, and
magical pairs retain their native aliases and callback order. Those paths
still need a separate read audit. The native C/C++ fixture executes 3,072 actual
arithmetic/comparison opcodes on six executors against two writers performing
1,024 scalar representation changes, with no caller-held read claim around an
opcode. Disabling operand preparation must expose an unguarded cached read.
The TSan target instruments Perl and the fixture and checks the deliberate
allocator-race control.

Ordinary published array/hash element reads now retain the actual element head
before releasing the container's read claim. A private mortal holder keeps that
head alive through the act's temporary scope, including yields, exceptions and
task abandonment, without changing its flags or copying away its alias identity.
The claim ends before the opcode returns; a later container deletion or resize
does not need to retain its old table just for an already-loaded operand.
Coverage includes read-only and existing writable `aelemfast`/`aelemfast_lex`,
`aelem`, `helem`, and intermediate/final `multideref` elements. Writable
arguments retain the original scalar alias even when a later argument or the
callee yields and another act deletes or replaces its slot. Existing undefined
scalars remain writable aliases; lvalue-returning subs retain their identity.
Localization keeps its act-local path. Missing writable elements are rechecked
under a container writer before creation, then retained before that writer
ends. They retain Perl's deferred-lvalue behavior: passing an absent element
need not create it until the callee assigns to the alias.
Hash keys on this path are ordinary cached strings, including UTF-8 and embedded
NULs; numeric, tied and overloaded keys retain the native conversion path. Active
act-local element overlays and magical containers retain their existing paths.
The `multideref` diagnostic cursor is also act-local. The C/C++ fixture runs
seven readers through 896 read-only and 896 writable opcode loads while a writer
removes elements and clears containers. Bypassing retention must fail its
lifetime assertion before attempting a dangling read.

Deferred lvalue resolution guards both its delegate and its original container
through lookup, creation and ownership transfer. It retains the resolved cell
and commits the delegate's fields before dropping its old owners. Nonextendible
array misses release their old array owner as well. Publication follows owned
lvalue targets, including deferred containers, while skipping native tied
delegates whose target field holds an opaque pointer. Autovivification guards
the source scalar and publishes a new referent before exposing its reference.
`make perl-materialization-test` checks created aliases across yields, deferred
and negative-index behavior, conflict rejection, exceptions and abandonment.
Its C/C++ fixture creates, resolves and vivifies 896 actual opcode results while
another executor clears their containers. Two standalone embedding regressions
also cover deferred owner leaks and premature target release in native Perl.
Focused `perl-materialization-tsan` and `perl-materialization-memcheck` targets
exercise these paths under ThreadSanitizer and Valgrind.

Ordinary strong scalar/array/hash references now retain their extracted
referent under a short source claim before releasing that claim. A second
short claim checks the referent's type and object status; no claim spans
index/key evaluation.
Coverage includes `rv2sv`, `rv2av`/`rv2hv` and the array/hash reference actions in
`multideref`, including its existing-reference vivification fast paths. If
another act assigns a new reference into the same source scalar while an index
or key callback yields, the opcode still uses the originally extracted array
or hash. Scalar dereferences likewise retain their original scalar head through
later operand evaluation, writable arguments, compound assignment and lvalue
returns. Nested references retain each extracted head; scalar dereferences
still perform requested autovivification under the existing writer protocol.
Tied scalar referents and native lvalue delegates retain their callbacks and
alias identity. Retaining the source scalar alone would leave its earlier
referent unprotected. The C/C++ fixture checks 1,344 scalar/aggregate dereference
invocations, including nested scalar loads and scalar lvalue vivification,
across 1,920 source replacements after extraction claims have ended. Exceptions
and abandoned callbacks release these referent holders with the act's temporaries.
Weak references, blessed referents, tied/magical sources and mismatched types
keep their native paths; rejected captures drop their temporary strong pin
before falling back, preserving weak behavior, overload and destructor timing.
Scalar reference localization retains its native path and diagnostics.
`make perl-references-test` includes scalar lifetime, conflict, callback and
cleanup regressions. Its native fixture includes a separate control which
bypasses only scalar capture and must expose the missing lifetime reference.

The parallel preview covers the listed scalar destinations, plain binary inputs
and ordinary element loads; the opcode and XS audits remain incomplete.
Weak/object reference extraction and in-place RV changes outside
the audited vivification path, mixed key/magic paths, other aggregate fast
paths and direct XS field access remain open. The caller must already retain the aggregate passed
to an element load; aggregate reference extraction now establishes that lifetime
for the ordinary strong-reference paths listed above.
Raw `SvPVX`/`AvARRAY`/`HvARRAY` access needs an explicit borrow or external
lifetime management. Magical containers, mutable-buffer escapes, element-overlay
base writes, remaining regex and interpreter caches, and direct XS access
still need audits before general multi-core Perl use.
Raw cache predicates and direct field access still require explicit claims or
external synchronization. Read-only COW diagnostics are rejected when enabling Wump because their
page protection changes cannot share the concurrent byte-counter protocol.
Channel messages copy the outer scalar and retain reference
identity; pending messages own their references until receive or scheduler cleanup.

The first publication barriers now mark generic Perl value graphs when they
escape through act captures, inherited references, channels, package-variable
access, or stores into already published values. The walk follows references,
array/hash storage, captured/state and shared constant pad cells, refcounted
magic objects, native class fields, constant-sub values, and flagged
refcounted XSUB payloads. Native regex roots include callback closures,
embedded regexes, and SV-backed engine tables; custom engines contribute
their common Perl roots while their private pointers remain opaque.
It handles cycles and deep graphs without recursive descent, and invokes no
`FETCH`, overloaded conversion, or hash-iteration callbacks. Temporary work
roots are released before the barrier returns; metadata itself owns no values.
Stores made outside an act still propagate into previously published values.
Stores made by destructors during abandoned-task cleanup also propagate.
Fresh local bindings and shallow snapshot cells stay independent; their
referents are published when shared with a child. New closure instances are
classified after capture, independently of their prototypes. Fields initialized
after a class instance escapes also propagate publication. Native inversion
lists cannot carry extension magic and are treated as shared leaves; that
classification does not make regex read caches safe for concurrent use.

### Publication and value safety

`Wump::is_shared($reference)` inspects this experimental publication metadata.
An unmarked value is **unclassified**, not proven exclusive to one act.
Native code that writes raw AV/HV storage, IO internals, private custom-regex
storage, unflagged XS payloads, and other hidden roots still need a publication
audit before these markers can select non-atomic counters or establish general
parallel safety. Publication adds metadata and magic-path overhead. The string
benchmark checks scaling for private buffers; small arithmetic workloads can
be slower with multiple slots because of shared metadata contention.
The marker uses extension magic and preserves the SV-head layout. Its
callbacks preserve native magic, localization, and weak-reference lifetimes.
Run `make perl-publication-example` to see publication through a channel and
an act capture while retaining the original shared object.

Ordinary Perl compute loops share the configured execution slots automatically.
The Wump runloop polls the runtime every 256 opcodes and gives other runnable
acts a turn after roughly 10 ms since the dispatch's first eligible poll.
An empty busy loop therefore no longer needs an explicit `yield` to let
other acts or timers progress. This is safe-point preemption: it does not
interrupt an opcode or a blocking native call. Compilation, execution on Perl's
auxiliary callback stacks (including destructors, magic, sort, and regex
callbacks), and teardown defer automatic switches until ordinary runtime
execution resumes. Explicit yields
retain their existing behavior in supported callbacks. Ordinary scripts
without Wump retain the upstream runloop.

This prototype does not implement `sel` or automatic Perl I/O/XS handoff.
Ordinary blocking Perl operations still occupy their execution slot.
With multiple slots, runtime `eval STRING`, `require`, `do FILE`, and dynamic
regex compilation are rejected before compiler entry. Load dependencies with
`use` before execution. A compile lock remains future work.
Unaudited XS calls are also rejected with multiple slots. An audited extension
can register an XSUB with `Perl_wump_xs_allow(aTHX_ cv)` during bootstrap,
before Wump execution begins; registration covers that native entry address.
This declaration requires an actual audit of its storage and callbacks.
The pinned core now registers Time::HiRes `time`, `gettimeofday`,
`clock_gettime`, and `clock_getres`, plus Unicode::Normalize `NFC`/`NFD`
and their `NFKC`/`FCC`/`NFKD` aliases. Load these modules and resolve needed
autoloaded clock constants at compile time. Parallel normalization snapshots
plain scalar inputs before conversion; references, other magic, and malformed
UTF-8 are rejected before native normalization buffers are allocated.
Other entries in these modules remain gated, including blocking sleeps,
process timers, and unaudited normalization helpers. Rejections name the XSUB.
Single-slot execution retains the existing runtime compilation and XS paths.
Mutation of existing subs while tasks are suspended and debugger/general
multicall integration remain unsupported. Scope-exit destructors see the
enclosing binding and can spawn tasks.
Abandoning a task suspended inside a destructor remains unsupported, and
destructors invoked during task teardown cannot schedule. Task teardown
releases abandoned Perl frames and their owned values while their C stacks
are still mapped; it is not cancellation
that resumes the task's ordinary code.
