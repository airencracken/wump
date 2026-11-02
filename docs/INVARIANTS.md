# Execution and memory invariants

Last reviewed: 2026-11-01, runtime source `8d78b10` with caller lifetime guard
`9638d8c`, pinned Perl 5.42.2. Incremental archive dependencies are fixed in
`4365dac`.
Scheduler continuation: CTX-8/CTX-9 describe the ownership and clock-polling
change based on `2b66dfa`; its source hashes and validation are recorded in
[scheduler-owner-machine.json](../bench/scheduler-owner-machine.json).
The solitary-continuation extension to CTX-8 is recorded in
[scheduler-yield-machine.json](../bench/scheduler-yield-machine.json).

These are requirements for preserving the current supported behavior, not a
claim that every Perl or XS path has been proved safe. Enforcement and tests
below are bounded evidence. Proposed architecture in `DESIGN.md` is not a
substitute for implementation. See the [audit](EXECUTION-CONTEXT-AUDIT.md) for
unsupported behavior, open risks, and the remaining test matrix.

## Ownership vocabulary

| Classification | Meaning |
| --- | --- |
| Task-local | Logical act storage, independent of the native thread executing it. The main act borrows root interpreter fields/stacks; children have separate storage. |
| Executor-local | Allocation/cache state belonging to a runtime execution slot (P), not an act or permanently one pthread. |
| Interpreter-global | Root interpreter storage, or explicitly identified process-global storage. This does not establish safe concurrent access. |
| Intentionally shared | Shared code, roots, values or metadata whose individual access protocol must be stated. |
| Unresolved | Ownership/access coverage has not been established; this is neither a private-value proof nor a demonstrated defect. |

A task-local pointer does not make its pointee task-local. Captured/state
lexicals, CVs, COPs, GVs, referents and IO handles can remain shared.

The [field catalogue](state-inventory.tsv) includes all 344 interpreter and 57
process-variable declarations in the pinned headers, plus eight Wump
interpreter fields. Conditional declarations are included even when this Linux
build does not compile them. Native C statics, external TLS, extensions and
opaque native payloads require separate inventories; the catalogue is not a
complete inventory of every mutable byte reachable from Perl.

## Execution context

**CTX-1 — Select state by act and interpreter identity.** `aTHX` remains the
shared interpreter pointer. Task selection must check interpreter identity;
an inactive or different interpreter must use its own root fields. The sticky
`Iwump_context_seen` flag is a selection optimization, never a publication or
ownership proof, and must not be cleared while another executor can use it.

Enforcement: [selector generation](../perl/apply.pl#L259),
[activation](../perl/core/wump_core.c#L14). Evidence:
[task-context](../tests/perl/task-context.c),
[clone-context](../tests/perl/clone-context.c),
[ordinary transitions](../tests/perl/ordinary.t).

**CTX-2 — Reselect executor state after migration.** Dispatch must activate the
act, destination allocator and interpreter context before executing its code.
An act pointer owned by the current C invocation can remain stable. Native TLS
addresses, current-M pointers and allocator pointers cannot be cached across a
possible scheduling call. A slot can move to another OS thread after handoff.

Enforcement: [dispatch hook](../perl/core/wump_core.c#L387),
[scheduler](../runtime/src/sched.c#L595),
[allocator selection](../perl/core/wump_alloc.c#L15). Evidence:
[native context](../tests/test_context.c),
[syscall handoff](../tests/test_syscall.c),
[actual parallel execution](../tests/perl/parallel.t).

**CTX-3 — Distinguish stack storage, stack addresses and value lifetimes.**
Bounded numeric admission may read opcode, phase and operand-stack fields from
the act owned by its C invocation, selecting interpreter fields for the main
act. It performs no Perl callbacks or coroutine suspension before leaving the
numeric region. Executor allocation/reader state still selects the current
executor dynamically. This does not permit caching native TLS addresses or
keeping stack addresses across callback-capable operations.

Operand/context/mark/save/scope/temporary stacks belong to the act. A live SV
reference does not keep an SV** stack address stable through stack growth.
Core and XS callers must obey native SP refresh rules across callbacks and
separately retain values/referents they still use.

`SvTEMP` is not a membership test for the temporary stack: argument/assignment
handling can clear it while temporary references remain. Publication must
transfer every matching temporary reference to a private RV holder before the
head becomes shared, even with TEMP already clear and with duplicate temporary
references. Ordinary cleanup then drops the holders without writing shared
head flags. Refcounts and values must balance on normal and exceptional cleanup.

Enforcement: [task fields](../perl/taskvars), generated core accessors and
audited load/capture patches. Evidence: [active callbacks](../tests/perl/active.t),
[forced stack growth](../tests/perl/scalar-lookup.c),
[stack values](../tests/perl/stack-loads.t),
[referents](../tests/perl/reference-loads.t).
The [native ownership fixture](../tests/perl/owned.c) checks both TEMP-set and
TEMP-cleared publication, including duplicate temporary owners.

**CTX-4 — Call-frame privacy must preserve lexical identity.** Ordinary locals,
arguments and recursive depth are isolated per act/CV frame. Captured and
`state` variables retain their Perl identity and may be intentionally shared;
they do not silently become private because an act calls the subroutine.

Enforcement: [CV preparation](../perl/core/wump_core.c#L247). Evidence:
[recursive tasks](../tests/perl/tasks.t),
[differential caller/wantarray](../tests/perl/context-compat.t).

Ordinary callee resolution may snapshot a nonmagical reference, its referent
and their head flags in one existing metadata region. That region cannot
allocate, call Perl or suspend. No snapshot may survive magic or overloaded
dereferencing: those paths must re-read the resulting callee after the
callback. Autoload, debugger entry, CV publication/preparation, argument and
return context retain their existing paths. Evidence:
[callee resolution and callback compatibility](../tests/perl/callee.t),
[source upgrade/idempotence](../tests/perl/patcher.pl).

**CTX-5 — Restore the correct dynamic scope before calling user cleanup.**
Bindings are act-owned, their target GP identity is retained independently of
later aliases, and a popped binding is detached before its value can invoke
DESTROY. Ordinary `local` snapshots and `pocket` exclusions retain their
existing distinct semantics. Unwinding must not overwrite a later root write.

Enforcement: [localization](../perl/core/wump_local.c#L19),
[elements](../perl/core/wump_elements.c),
[cell-owned magic](../perl/core/wump_magic.c). Evidence:
[local](../tests/perl/local.t), [elements](../tests/perl/elements.t),
[pocket](../tests/perl/pocket.t), [separators](../tests/perl/separators.t).

**CTX-6 — Implicit state has multiple owners.** `$_`, `$@`, `$^R`, match context
and the selected argument/call stacks use task storage. Match-result cells and
named-capture cursors need their own act caches. `pos()` remains a property of
the subject SV. Warning/die hooks and separator caches follow their actual
scalar cells/overlays. Process cwd, credentials, environment and native signal
handlers must not be assumed act-local.

Enforcement: [scalar selection](../perl/core/wump_scalar.h),
[regex cells](../perl/core/wump_core.c#L89),
[magic caches](../perl/core/wump_magic.c#L85). Evidence:
[regex](../tests/perl/regex.t), [hooks](../tests/perl/hooks.t),
[context comparison](../tests/perl/context-compat.t). Process-wide state is an
open policy boundary, not certified by these tests.

**CTX-7 — Native context preservation is specific.** Runtime switches preserve
task errno, SysV callee-saved registers, MXCSR and the x87 control word. Do not
infer isolation of arbitrary C-library TLS, the complete floating-point
environment, native-library state, or pthread identity from those saves.

Enforcement: [assembly](../runtime/src/ctx_x86_64.S),
[errno accessors](../runtime/src/error.c). Evidence:
[context tests](../tests/test_context.c), [handoff tests](../tests/test_syscall.c).

**CTX-8 — Queue exclusion follows execution-slot ownership.** Only the current
owner of a P may push/pop its local FIFO. With one immutable execution slot,
there are no thieves and that owner cannot concurrently be asleep in the
scheduler: local push/pop need neither the queue mutex nor a scheduler wakeup.
The native thread donating its P must stop touching the local queue before the
replacement acquires ownership under the runtime mutex. A single P is not a
promise of a single native thread. Multiple-P queues still need exclusion for
stealing. External poller wakeups, syscall returns and local overflow must use
the synchronized global path; they cannot use the single-owner shortcut.

A saved continuation queued by its own live scheduler may omit its wakeup
notification and epoch increment when it is the only task in that local queue.
Check depth under the queue mutex on multiple slots. The owner has not
entered idle accounting and will
search for work again, so a sleeper is not needed to consume that continuation.
New spawns, channel readiness, additional local work and global overflow must
retain their publication/wakeup protocol. This omits no context switch,
dispatch hook, timer expiry, global poll or shutdown/deadlock check.

Enforcement: [local queues and handoff](../runtime/src/sched.c).
Evidence: [coordination contract before/after handoff](../tests/test_scheduler.c),
[overflow/FIFO/context tests](../tests/test_runtime.c),
[native-call progress](../tests/test_syscall.c),
[all-workers-idle external wakeups](../tests/test_io.c).

**CTX-9 — An empty global queue observation has one-dispatch scope.** The
scheduler expires timers and observes global queue membership under the runtime
mutex. Only the immediately following work search can use that observation to
omit an elapsed-time clock read. Periodic global polling remains unconditional;
an empty local queue always checks the global queue; pending global work keeps
the elapsed-time fairness rule. The publication epoch and external wakeup
protocol remain required. No observation may survive a dispatch or be used to
skip timer expiry, shutdown checks or idle/deadlock validation.

Enforcement: [work search and dispatch](../runtime/src/sched.c).
Evidence: [clock-call budget](../tests/test_scheduler.c),
[timer/compute fairness](../tests/test_runtime.c),
[external wakeups during local compute](../tests/test_io.c).

**CTX-10 — Reuse begins only after task retirement.** Completed tasks run
context cleanup on the scheduler stack before their stack pages can be
discarded. TSan fibers are destroyed and ASan stack memory is unpoisoned before
reuse. The owning P alone accesses its 32-entry hot cache; the runtime mutex
protects the shared 1,024-entry cold cache. Cold mappings release all writable
pages below the metadata page, preserving both that page and the protected
guard. Failure to release pages falls back to unmapping. Reuse resets the
canary, saved errno, context/cancel hooks and initial machine frame. Cache links
remain independent of the mapping registry, which owns every retained mapping
through final shutdown. Abandoned tasks must never enter either reuse cache.

Enforcement: [retirement and allocation](../runtime/src/sched.c),
[page discard](../runtime/src/stack.c).
Evidence: [reuse, residency, caps, failures and native handoff](../tests/test_stack_cache.c),
[context cleanup](../tests/test_context.c), [guard page](../tests/test_runtime.c).

## Values, access and reclamation

**MEM-1 — Reference counts establish lifetime, not mutation safety.** Standard
C/C++ SV counter helpers are atomic in this fork. Acquiring a new reference
requires an already valid owning reference or protected source. Direct legacy
lvalue writes to counters, flags, bodies, HEKs or aggregate storage require
their own audit. Atomics do not make an SV's type/body/cache transition safe.

Enforcement: [counter helpers](../perl/refcount.pl),
[keys](../perl/core/wump_keys.c). Evidence: [rooted counter stress](../tests/perl/refcount.c),
[allocation/exchange](../tests/perl/allocator.c). The rooted counter test alone
does not exercise concurrent destruction or value mutation.

**MEM-2 — Publication precedes cross-act exposure.** Closure captures, messages,
package values and stores into published owners must expose the supported
reachable graph before another act uses it. Pending publication is not a
completed graph proof. Graph walks must not invoke Perl callbacks. Known SV
edges and flagged native payloads do not cover arbitrary XS pointers or custom
regex-engine private storage.

AV/HV element-overlay markers must be installed during initial publication,
before declaring the aggregate shared. First localization cannot change a
header already visible to raw native aggregate readers. Marker-aware plain
storage checks may accept this inert marker; an active element overlay still
requires its own view handling. Shared argument heads must not have TEMP
cleared by sort, grep/map or reference construction.

Enforcement: [publication](../perl/core/wump_publish.c),
[message send](../perl/core/wump_core.c#L761). Evidence:
[publication](../tests/perl/publication.t), [hidden roots](../tests/perl/hidden-roots.t).
Unregistered storage is not a blanket proof of exclusive ownership.

**MEM-3 — Exclude writers before reading mutable heads.** On supported published
paths, classify/acquire a reader claim before inspecting flags, bodies or
caches. Core scalar classification and that claim are one operation. A logical
writer belongs to an act; another act must not pass it. A writer's own scalar
conversion must still install its original cache where native Perl requires it.

Enforcement: [claims](../perl/core/wump_memory.c#L458),
[core conversion](../perl/core/wump_reads.c#L28),
[mutation](../perl/core/wump_memory.c#L706). Evidence:
[private/shared contracts](../tests/perl/owned.c),
[read/write contention](../tests/perl/read-claims.c),
[conversion behavior](../tests/perl/read-cache.c).

**MEM-4 — Bound native exclusion; preserve logical claims through callbacks.**

Class predicates and reference-name lookups share stash flag words with
overload-cache initialization. Read those fields under metadata exclusion.
Parallel reference-name assignment must use an owned snapshot and release its
guard before overwriting a destination that can run user cleanup. Evidence:
[cold-cache races and yielding destination cleanup](../tests/perl/parallel.t),
[native ref destination](../tests/perl/root-fixture.c).

A native metadata mutex/short reader announcement cannot span scheduling or
user callbacks. Logical writer/capture guards can survive supported callbacks
and must unwind on errors and abandonment. Use the guarded APIs rather than
assuming a direct internal mutex call installs every scheduling prohibition.

Enforcement: [metadata guard and scheduling check](../perl/core/wump_memory.c#L687),
[numeric admission](../perl/core/wump_memory.c#L359),
[callback snapshots](../perl/core/wump_reads.c#L57). Evidence:
[native integration](../tests/perl/native-integration.t),
[numeric protocol](../tests/perl/numeric-admission.c),
[operand callbacks](../tests/perl/operands.t).

**MEM-5 — Proofs end at their boundary.** A released reader claim does not
authorize a later raw read. Allocating snapshots establish their own capture;
callbacks can change representation or publication, so reacquire/reclassify
afterward. Retaining an RV and retaining the extracted referent are different
lifetime obligations.

Enforcement: [read snapshots](../perl/core/wump_reads.c#L82),
[capture tokens](../perl/core/wump_memory.c#L803). Evidence:
[reads](../tests/perl/reads.t), [operands](../tests/perl/operands.t),
[scalar referents](../tests/perl/scalar-references.t).

**MEM-6 — Retire storage while it can still be observed.** Borrow pins protect
old buffers/bodies/tables; mutation must detach or preserve the storage promised
to a live borrower. Reclamation waits for the relevant domain's pins. This is
the implemented conservative pin/retirement protocol, not the design's proposed
general safe-point tracing collector. Long-lived pins can defer reclamation.

Enforcement: [retirement](../perl/core/wump_memory.c#L566),
[SV storage](../perl/core/wump_storage_sv.c),
[AV storage](../perl/core/wump_storage_av.c), [HV storage](../perl/core/wump_storage_hv.c).
Evidence: [memory tests](../tests/perl/memory.t), [reclamation](../tests/perl/reclamation.c).

**MEM-7 — Merge executor arenas only after their users stop.** Freeing on a
different executor is supported; it does not permit early arena release.
Dispatch/cleanup select the current executor, all executors stop before root
merge, and the interpreter owns final arena destruction.

Enforcement: [allocator merge](../perl/core/wump_alloc.c#L48),
[bridge shutdown](../perl/core/wump_core.c#L646). Evidence:
[allocator exchange](../tests/perl/allocator.c), [repeated entry](../tests/perl/entry.c).

## Suspension and shutdown

**SUSP-1 — Automatic and explicit suspension are different contracts.** The
active runloop polls every 256 opcodes. Automatic polls defer during parser
activity, auxiliary callback stacks, critical regions and teardown. Explicit
yielding callbacks can be supported during normal execution; automatic
deferral does not prove that every explicit reentrant callback is safe.

Main-act INIT/END execution is not abandoned-task teardown. END blocks run
before scheduler shutdown and can explicitly schedule on covered paths;
interpreter global destruction after runtime shutdown is a separate phase.

Enforcement: [runloop](../perl/active.pl#L45),
[checkpoint gate](../perl/core/wump_core.c#L27). Evidence:
[preemption](../tests/perl/preempt.t), [nested calls](../tests/perl/context-compat.t).

**SUSP-2 — Park before exposing a resumable waiter.** Primitive locks transfer
to scheduler-side unlock hooks only after saving the coroutine context.
Shutdown detaches channel/select/timer/I/O waiters before interpreter cleanup
and before unmapping stacks. Losing select cases must also be detached.

Enforcement: [parking](../runtime/src/sched.c#L631),
[shutdown ordering](../runtime/src/sched.c#L919),
[channel detach](../runtime/src/chan.c#L140), [I/O detach](../runtime/src/io.c#L484).
Evidence: [runtime](../tests/test_runtime.c), [select](../tests/test_select.c),
[I/O](../tests/test_io.c).

**SUSP-3 — Normal destruction and abandoned-task teardown differ.** A normal
scope-exit destructor can use supported yielding callbacks. Once the bridge
is freeing an abandoned act on the scheduler stack, cleanup must not resume its
old body or schedule another act. Stacks remain mapped for registered cleanup;
unwind runs against the correct act context and exceptions are caught locally.

Enforcement: [Perl cleanup](../perl/core/wump_core.c#L426),
[context cleanup](../runtime/src/sched.c#L401). Evidence:
[entry shutdown](../tests/perl/entry.t), [local cleanup](../tests/perl/local.t),
[parallel normal destructors](../tests/perl/parallel.t).

**SUSP-4 — Cancellation is cooperative, runtime-wide shutdown.** The public
Perl API has no per-act cancellation or implicit ancestry join. Main return,
panic or deadlock ends the runtime. Waitgroups are explicit. C code that never
returns/polls/parks and entered native calls that never return can prevent
shutdown; no asynchronous cancellation guarantee may be inferred.

Enforcement: [public contract](../runtime/include/wump.h),
[scheduler](../runtime/src/sched.c#L701), [Perl panic](../perl/core/wump_core.c#L230).
Evidence: [entry](../tests/perl/entry.t), [syscalls](../tests/test_syscall.c).

## Compatibility and extension boundaries

**COMPAT-1 — Availability is not activation.** Ordinary legacy programs retain
their meaning without importing Wump. `WUMPPROCS` alone must not start actors or
activate the multi-slot XS/compiler policy. Existing Perl names and syntax must
not be silently reinterpreted merely because the fork is installed.

Enforcement: [opt-in](../perl/lib/Wump.pm), [main entry](../perl/apply.pl#L464).
Evidence: [ordinary](../tests/perl/ordinary.t), [entry](../tests/perl/entry.t),
[legacy syntax](../tests/perl/pocket-deparse.t),
[same-version context differential](../tests/perl/context-compat.t),
[legacy differential](../tests/perl/legacy-compat.t).
The legacy fixture compares names/prototypes, lexical hints/warnings, hooks,
selected output and read-only C-locale queries with stock, including after
`require Wump` without import. Even invalid `WUMPPROCS` must remain inert until
activation. This evidence does not reclassify locale or IO state as task-local.

**COMPAT-2 — An admission label is entry-specific.** Parallel XS admission uses
native entry addresses registered before execution, with a constant-XS
exception. It does not certify a whole module, every argument type or callback
path. The gate depends on configured execution slots, even with one actor.
Single-slot permission is not proof of arbitrary XS reentrancy or affinity.

Enforcement: [XS gate](../perl/core/wump_memory.c#L117),
[audits](../perl/xs.pl). Evidence: [XS boundaries](../tests/perl/xs-parallel.t),
[JSON default-output boundary](../tests/perl/context-compat.t).

`utf8::encode` and `utf8::decode` admit only plain scalar mutation in parallel.
Their logical writer claim spans conversion and SETMAGIC, including warning
hooks; no native mutex spans those callbacks. Exceptions unwind the claim and
the XSUB refreshes its stack pointer after callbacks. This is not permission
for arbitrary magical inputs or other UTF-8 entries.

**COMPAT-7 — Module scratch state follows invocation lifetime.** JSON::PP's
mutable encoder/parser scalars have dynamic call-local bindings; its default
functional codec is constructed before execution. Yielding and nested codecs
must preserve options, parser cursor, errors and incremental state.

Ordinary local bindings select private storage without inspecting the shared
root head. Search candidates in binding order: resolve the root magic kind
only when a candidate carries a magic kind, and retain magic-before-GP
precedence at that candidate. Pocket filtering happens before matching during
inheritance. A direct GP match cannot be moved ahead of an earlier magic
alias. This keeps alias/hook precedence while avoiding a metadata mutex on
ordinary private scalar loads.

Each binding retains its GP independently of later glob replacement. Its
private GV holder is allocated directly with a diagnostic name and a GP
reference; creating a disposable GP is unnecessary. Release the binding's
value before its saved holder/origin references, preserving ordinary native
GP destruction. The holder remains a valid named GV if it becomes the GP's
last owner.

The successful localization header check cannot suspend or call user code.
Only parallel execution needs metadata exclusion around that short prefix;
one execution slot has a single Perl owner. Validation returns the builtin
magic kind it has already checked, so binding creation must reuse it rather
than immediately repeat the shared-root classification. This does not remove
parallel guards or admit unsupported magic.

Evidence: the C/C++ [scalar lookup fixture](../tests/perl/scalar-lookup.c)
counts native mutex calls around selection, and
[binding regressions](../tests/perl/local-lookup.t) cover alias precedence,
hooks, inheritance, scope unwind and final release of a replaced GP.

The active `PL_dbargs` cache resolves the current act's `DB::args` binding.
Carp localizes that scratch array per `caller_info` invocation. Implicit
task-lifetime bindings stay below lexical save-stack bindings and are not
inherited. Debugger argument arrays borrow their frame's SVs: still-borrowed
arrays cannot be published. Reference construction may reify them into owning
storage; once published, they cannot be reset to borrowed storage by another
caller inspection. Shifted-out slots are undefined in active
execution. This does not certify the general Perl debugger.

The native builtin scalar heads for `$!`, `$^E`, `$?`, `$^F` and `$.` are also
act-local on their canonical GV paths; logical values still come from the
existing errno/status/IO state. This prevents cache-flag races, not concurrent
ownership of shared filehandles or arbitrary magical aliases.

Evidence: [UTF-8 XS](../tests/perl/utf8-xs.t),
[ordinary reentrancy](../tests/perl/json-state.t),
[parallel JSON](../tests/perl/json-parallel.t),
[caller and Carp](../tests/perl/caller-parallel.t),
[publication/localization](../tests/perl/element-mark-parallel.t),
[namespace and class caches](../tests/perl/gv-parallel.t).

**COMPAT-3 — Compiler and embedding limits remain explicit.** Runtime string
eval/require/do-file and runtime regex compilation are rejected with multiple
slots; block eval is distinct. `PL_parser` is not task-local. The Perl bridge
allows one active runtime process-wide; the C runtime's independent-runtime
support is a different contract. Sequential embedded interpreter entry is
tested; arbitrary simultaneous Perl runtimes/reentrant `perl_run` are not.

Enforcement: [compiler gate](../perl/active.pl#L55),
[regex gate](../perl/regex.pl), [bridge entry](../perl/core/wump_core.c#L610).
Evidence: [parallel rejection](../tests/perl/parallel.t),
[embedding](../tests/perl/entry.c), [native independent runtimes](../tests/test_runtime.c).

**COMPAT-4 — Native syntax preserves the scheduling contract.** The lexer
selects `OP_WUMPYIELD` only with the lexical `Wump/keywords` hint. Qualified
names, methods, implicit hash keys and scopes without that hint retain normal
Perl lookup. The opcode has no Perl/XS call frame or mutable global state.
It checks the same metadata/publication exclusion as the XS path, requires a
running act and an already-published operand stack before suspension, and
reselects stack state when needed after resumption. Scalar/list results remain
undef/empty. Opcode definitions,
dispatch/check tables, prototypes and B metadata must agree; regeneration uses
the pinned upstream generator and rejects unknown opcode input. `Opcode`
classifies it with thread operations, and compilation must honor opcode masks.

Nullary yield does not change operands before suspension. Void/list execution
can therefore leave the already-published stack pointer untouched; scalar
execution obtains fresh stack state after resumption before pushing undef.
Call context is selected from the current act's opcode, retaining the usual
block-context fallback for an uncontextualized operation. Scheduling checks
may cache the act pointer only within their callback-free, non-suspending check.

Enforcement: [lexer and generation](../perl/yield.pl),
[native operation](../perl/core/wump_core.c), [lexical hints](../perl/lib/Wump.pm).
Evidence: [compiled form and observable behavior](../tests/perl/native-yield.t),
[metadata regeneration](../tests/perl/opcode-regeneration.pl),
[idempotent source upgrade](../tests/perl/patcher.pl).

**COMPAT-5 — Intrinsic lowering follows the original CV, not a name alone.**
The original imported `act`, `chan` and `sleep` CVs carry compiler checkers.
These are interpreter-owned compiler metadata, installed during module setup
and never admitted for modification through parallel XS dispatch.
Perl first applies its existing prototype/closure rules, then the checker can
replace eligible calls with their unary core operations under the lexical
Wump hint. An omitted channel capacity becomes a zero constant. Qualified `Wump::` calls,
ampersand/indirect calls and custom wrapper CVs retain ordinary dispatch.
Namespace identity, not the CV's mutable display name, identifies qualified
compatibility calls. The checker self-reference is non-owning; it must not
create a CV reference cycle. Native creation retains its argument on the
operand stack until the common spawn helper owns the callback CV, refreshes
SP after helper callbacks, and shares XS snapshot/failure cleanup. Channel
creation and sleep retain their input on the operand stack while their shared
helpers can invoke callbacks or suspend; all native paths refresh SP afterward.
Capacity/duration validation, channel ownership and timer scheduling are shared
with XS. All operations belong to Opcode's thread group and honor masks,
including cleanup of the synthesized default capacity on compilation failure.

Enforcement: [compiler checker and spawn helper](../perl/core/wump_core.c),
[registration](../perl/lib/Wump.pm), [metadata](../perl/yield.pl).
Evidence: [native compilation, lifecycle and override checks](../tests/perl/native-act.t),
[constructors, timers, inputs and masks](../tests/perl/native-scalar-ops.t).

**COMPAT-6 — Native channel dispatch follows the resolved implementation.**
Normal method/CV resolution completes before the core recognizes one of the
three immutable channel entry addresses. Existing XS admission and CV
publication still run. Only those entries skip the Perl wrapper/XS invocation;
custom CVs, overrides, unrelated methods and MRO changes retain normal dispatch.
The original entries remain real XS functions for paths needing the upstream
argument adapter, including implicit forwarding and tail calls. Debugger,
lvalue and experimental refcounted-stack paths keep their adapter.

The direct path pops exactly its own argument mark, checks arity, materializes
PADTMP arguments as XS does and retains operands on the act-owned stack while
helpers can invoke magic, throw or suspend. Stack indices survive growth;
SP is refreshed before replacing arguments with context-appropriate results.
Payload scalars are copied and references published by the same helper as XS.
Received values remain mortal through the caller statement, including void
receives. Runtime/ID validation still uses the registry; no channel pointer,
method cache or native-thread address is cached by this optimization. No new
mutable interpreter state or cross-executor ownership is introduced.

Enforcement: [entry hook](../perl/apply.pl), [dispatch and shared helpers](../perl/core/wump_core.c),
[method aliases and older controls](../perl/lib/Wump.pm).
Evidence: [contexts, callbacks, lifetime, overrides and migration](../tests/perl/native-channel.t),
[previous-guard upgrades](../tests/perl/patcher.pl),
[channel workload verification](../tests/perl/matrix-bench.t).

## Maintenance

Every change introducing a mutable field, native cache, callback, escape path
or suspension point must update its ownership/access classification and name
the invariant it relies on. Include normal return, exception and abandonment
obligations. Update the catalogue after reviewing changes, not by assigning
every new field a safe category. The inventory check runs in `perl-test`.

After reviewing classification changes, regenerate with
`perl tools/state-inventory.pl /path/to/private/perl-5.42.2/source` and run
`make perl-state-inventory-test`. The generator's explicit shared/restricted
maps require review; remaining fields default to unresolved. Regeneration
does not constitute a concurrency audit.

Keep a stock differential where semantics should match, distinguish one actor
from many cooperative actors and from demonstrated parallel overlap, and
retain unsupported cases as unsupported. A passing selected suite is not a
claim of thread safety, CPAN compatibility or production readiness.

Opt-in diagnostics must preserve results, publish lost-record counts, and
avoid adding blocking I/O or callback-capable work to scheduling-critical
paths. A complete actor/wait/cancellation trace is not implemented today.

Do not put private disclosure material or sensitive reproductions in these
documents or tests. Stop investigation of an independently encountered
potentially security-sensitive issue and use an authorized private reporting
channel; the public audit must remain non-revealing.

## Perl channel selection

**SEL-1 — Snapshot control inputs before parking.** Native `sel` copies every
case's scalar heads under metadata exclusion after checking existing writer
claims. Control arrays and fields must be plain; snapshotting invokes no tied
or overloaded callbacks. Resolve every enabled channel and validate every
case before attempting any channel operation. Publishing send candidates
precedes exposure to the C runtime. Snapshotting references retains identity;
it does not deep-copy payload graphs or make their later mutation safe.

**SEL-2 — A winning send has transferred ownership before return.** Its peer
may already have consumed and freed the message header when `wump_sel`
returns. Clear the selected send pointer without dereferencing it. Other
candidate headers and a selected received header remain exclusively owned by
the selector. Unlink those headers under registry exclusion and defer their
SV cleanup to normal mortal cleanup outside native locks.

**SEL-3 — Cancel native waiters before freeing Perl selection storage.** The
runtime cancels every task before unwinding abandoned Perl frames. An
abandoned selector may have committed without resuming to learn the winner;
its guard must never dereference candidate message pointers. The run registry
retains remaining messages until shutdown. Normal selections release their
snapshots and losing candidates before the caller's next statement. This
shutdown rule relies on abandonment ending the entire run; individual task
killing would require a separate ownership protocol.

Enforcement: [native selection](../perl/core/wump_select.c),
[C selection](../runtime/src/chan.c), [run teardown](../runtime/src/sched.c).
Evidence: [Perl selection tests](../tests/perl/native-select.t) and
[C selection tests](../tests/test_select.c).
