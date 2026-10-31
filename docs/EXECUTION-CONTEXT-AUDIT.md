# Perl execution-context and compatibility audit

Date: 2026-10-31. Audited runtime revision: `f5ce9cf`.
Base: pinned Perl 5.42.2, Linux x86-64, GCC 14.2.1, matched multiplicity,
ithreads/op-sharing and 64-bit configuration. Wump acts share an interpreter;
they do not use ithreads to schedule or clone actors.

This pass changes documentation and test/validation tooling only. It does not
change runtime behavior, add syntax, expand XS admission, or attempt an
architectural rewrite. No private disclosure sources were consulted. This
public audit contains no investigation or reproduction of private findings.
An independently encountered potentially security-sensitive issue must leave
this public workflow and use an authorized private channel.

## Findings at a glance

No new runtime memory-safety defect was demonstrated in this pass. That is not
evidence of general memory safety. The important distinction is between the
bounded behavior exercised below and the much larger set of unaudited state,
native extensions and direct field-access paths.

- All 63 selected interpreter fields have explicit act storage selection.
  Another 234 interpreter declarations remain classified as unresolved in the
  field catalogue; this counts declarations, not defects.
- Nested user call frames, arguments, scalar/list/void context, block eval,
  dynamic localization, captures, subject position and ordinary destruction
  match stock on the new differential fixture in each requested mode.
- A concrete integration limitation was observed: default
  `JSON::PP::encode_json` calls `utf8::encode`, which is rejected with multiple
  configured execution slots. It works without Wump usage and on one slot.
  This is an intentional XS admission boundary with a compatibility cost,
  not a newly discovered corruption defect.
- Compiler, process-state, native affinity, embedding and cancellation
  limitations remain material. A passing Mojolicious fixture does not remove
  those boundaries.

The durable [invariants](INVARIANTS.md) state what future changes must preserve.
The [complete declaration catalogue](state-inventory.tsv) supplies individual
names, ownership classifications, evidence and unresolved boundaries.

## Evidence and method

Read sources include the current architecture/implementation assessment,
`perl/taskvars`, selector and patch generation, the core bridge, CV/regex/local
state, publication/access/retirement machinery, allocator and XS boundaries,
the scheduler, stacks, channels/select, I/O, and the corresponding existing
tests. Proposed mechanisms in the design were checked against implementation.

The [machine-readable evidence record](audit-results.json) preserves binary and
pinned-header hashes, build configurations and fresh status manifests.

Fresh verification used the existing private build of `f5ce9cf` and an
unmodified Perl 5.42.2 control. Runtime source is unchanged, so the private core
was not rebuilt for this documentation/test pass. Native fixtures were rebuilt
against its headers/archive into the task's separate build directory.

| Fresh check | Result | What it establishes |
| --- | --- | --- |
| `context-compat.t` | 53 checks pass | Stock differential, matched core build configuration and explicit JSON admission boundary described below. |
| `state-inventory.t` | 6 checks pass | All pinned variable declarations are catalogued; task classifications match the selector list; added Wump interpreter fields match the actual generated layout. |
| Existing `PERL_SUITES` | All 35 pass | Current project behavior, including explicit unsupported cases. These suites have different mode coverage; they are not all stock differentials. |
| Native Perl drivers | task-context, scalar-lookup, owned, reads, entry, clone-context pass | Isolation/selectors, C/C++ scalar access, read/write contention, sequential embedding, root restoration and clone initialization on their covered paths. |
| C runtime binaries | test_runtime, test_context, test_select, test_io, test_syscall pass | Context/errno/FP controls, parallel work, native handoff, wait/cancel ordering, timers and poller behavior. |
| Mojolicious | Job/service suites and 48 live HTTP/WebSocket checks each at 1/4 slots pass | One prepared dependency stack, bounded admission, response verification, shutdown and listener reuse. |

The prior full upstream, ASan, targeted UBSan and Memcheck results at the same
runtime code remain **historical evidence**, not fresh audit runs. Full TSan
has a documented clone compatibility failure; whole-Perl MSan dependencies and
Helgrind/DRD tool failures remain unresolved. No sanitizer pass or suppression
was manufactured here, and no difficult suite was removed.

The first differential fixture used UTF-8 JSON serialization and failed at the
XS gate. That log is retained. The context-observation transport now uses
JSON::PP character output for its ASCII records, and separate assertions retain
the default UTF-8-output limitation on 2/4 slots. Thus context observations are
available without calling an unsupported serializer; the original integration
failure remains an unsupported matrix entry rather than being called a pass.

The stock comparison intentionally inspects the three nested **user** frames,
not the actor-entry wrapper/outer synthetic eval frames. Scheduler entry is an
intentional extra call boundary. It does not normalize away differences within
the inspected frames, value state or scope restoration. Execution-slot counts
are checked. The differential alone does not force overlap or migration;
`parallel.t` uses an executor rendezvous and verifies distinct slots and one
interpreter separately. Cooperative success is not counted as parallel proof.

## Execution-state inventory

### Declaration coverage

The TSV covers 344 declarations from `intrpvar.h`, 57 from `perlvars.h`, and
eight Wump fields appended to `struct interpreter`: **409 rows**. Conditional
platform/debug declarations are included, not claimed to be present in this
configured binary. Source locations refer to the pinned Perl 5.42.2 headers;
Wump enforcement references point to tracked sources.

For interpreter declarations: 63 task-local, seven executor-local, 24
intentionally shared, 16 interpreter-global/routed/compiler-restricted, and
234 unresolved. The 57 `G` declarations are physically process-global even
though they use the broad interpreter-global category. Their concurrency
assessment remains unresolved. Eight additional Wump fields are interpreter
globals. **Storage category is not an access-safety certificate.**

### Execution-critical groups

| State | Ownership / boundary | Enforcement and evidence |
| --- | --- | --- |
| Operand stack: `stack_sp/base/max`, `curstack`, `mainstack`; context stack through `curstackinfo->si_cxstack` | Task-local selection. Main borrows root stacks; children initialize their own. Stack element pointers and SV lifetime are separate obligations. | [task list](../perl/taskvars), [child initialization](../perl/core/wump_core.c#L564), [stack growth](../tests/perl/scalar-lookup.c), [active callbacks](../tests/perl/active.t). |
| Mark, save, scope and temporary stacks and indices/floors | Task-local. Their entries can retain intentionally shared values. | [task list](../perl/taskvars), [cleanup](../perl/core/wump_core.c#L426), [native context fixture](../tests/perl/task-context.c). |
| `op`, `curcop`, `curstash`, `curcopdb`, `multideref_pc` | Selected pointers are task-local; OP/COP/stash contents are shared or separately audited. | [selectors](../perl/apply.pl#L307), [active dispatcher](../perl/active.pl), [materialization](../tests/perl/materialization.t). |
| `curpad`, `comppad`, `comppad_name`, `compcv`; per-CV pad/depth map | Task-local frame selection; captured/state cells, names and code retain shared identity. | [CV preparation](../perl/core/wump_core.c#L247), [tasks](../tests/perl/tasks.t), [parallel first calls](../tests/perl/parallel.t). |
| `top_env`, `start_env`, `restartjmpenv`, `restartop`, `in_eval`, `eval_root/start` | Task-local native/Perl unwind context. No blanket foreign-library longjmp/reentrancy guarantee. | [task fields](../perl/taskvars), [child `JMPENV_BOOTSTRAP`](../perl/core/wump_core.c#L578), [differential eval](../tests/perl/context-compat.t). |
| `defgv`, `errgv`, `replgv`: `$_`, `$@`, `$^R`, argument AV | Private child cells; main uses root cells. Alias/local and regex-result handling need full accessor paths. | [GV selection](../perl/core/wump_core.c#L358), [scalar helper](../perl/core/wump_scalar.h), [scalar lookup fixture](../tests/perl/scalar-lookup.c). |
| `curpm`, `curpm_under`, `reg_curpm`, `regmatch_slab/state`; match-result cells and named-capture iterators | Task-local match context/caches. Regex code/templates and source SVs are separately shared. `pos()` belongs to the subject SV. | [regex cache](../perl/core/wump_core.c#L82), [regex patch](../perl/regex.pl), [regex tests](../tests/perl/regex.t), [parallel regex](../tests/perl/regex-parallel.t). |
| Localization lists, element overlays, sequence/pocket flags, cursor overlays | Task-local sidecars; GP/source identities and referred values are retained. Inheritable locals are copied at spawn; pocketed bindings are excluded. | [locals](../perl/core/wump_local.c), [elements](../perl/core/wump_elements.c), [local tests](../tests/perl/local.t), [pocket tests](../tests/perl/pocket.t). |
| `rs`, `ors_sv`, `warnhook`, `diehook`, `dowarn` | Root fields are global; audited access follows scalar-cell caches/active overlays. They are not all simply fields in `taskvars`. | [cell caches](../perl/core/wump_magic.c#L85), [hook routing](../perl/hooks.pl), [hooks](../tests/perl/hooks.t), [separators](../tests/perl/separators.t). |
| `last_in_gv`, `defoutgv`, `maxsysfd`, `statusvalue`, `statusvalue_posix` | Selected pointers/settings are task-local. Underlying IO handles, offsets/line counts, process descriptors and children are not thereby private. `$.` needs handle-aware interpretation. | [task list](../perl/taskvars), [native localization](../perl/core/wump_local.c#L124), [entry status/errno](../tests/perl/entry.t). General shared-handle semantics remain unresolved. |
| `tainted`, `delaymagic`, `localizing`, `generation`, scratch `na`, `hv_fetch_ent_mh`, `stashcache`, `phase`, warn/die recursion flags | Task-local selected state. This does not privatize process credentials, compiler globals or every associated cache. | [task list](../perl/taskvars), [generated selectors](../perl/apply.pl#L307). Remaining associated fields stay explicit in the TSV. |
| `parser`, `compiling`, compiler pad-introduction/index fields and other unselected compiler state | Interpreter-global; restricted rather than fully privatized. Automatic polls defer; parallel compiler entry is rejected. Cooperative/reentrant compile callbacks still need a complete state argument. | [checkpoint](../perl/core/wump_core.c#L27), [compiler gate](../perl/active.pl#L55), [parallel rejection tests](../tests/perl/parallel.t). |
| SV/body arenas, roots, signed counts, `nomemok`, hash randomness | Executor-local while active, root fallback otherwise. Native buffers/values can outlive a slot and can be freed elsewhere. | [allocator fields](../perl/apply.pl#L197), [activation/merge](../perl/core/wump_alloc.c), [allocator fixture](../tests/perl/allocator.c). |
| Stashes/GVs, `strtab`, shared keys, MRO/class caches, compiled CV/OP/COP data, immortals | Intentionally shared. Immutable identity, atomic lifetime and cache mutation are different properties. Guard coverage is bounded. | [keys](../perl/core/wump_keys.c), [parallel core patches](../perl/parallel.pl), [MRO](../perl/mro.pl), [XS](../tests/perl/xs-parallel.t). |
| Publication registry, logical writers, borrows, retired storage, numeric-reader registry | Interpreter-global domain with explicit native locking/atomics and act-owned tokens. Publication is not ownership inference for arbitrary opaque storage. | [memory protocol](../perl/core/wump_memory.c), [publication](../perl/core/wump_publish.c), [owned/read contention tests](../tests/perl/owned.c). |
| Root `Iwump_read_frame` / act `read_frame` | Root fallback / task-local callback frames; restored by save-stack guards. | [read frames](../perl/core/wump_reads.c#L4), [reads](../tests/perl/reads.t). |
| Wump task `interp`, `entry`, `cvs`, `regexes`, `locals`, `elements`, `element_iters` | Task-owned identity/root and sidecar containers; interpreter, CV, source glob and referent pointees can be shared. | [task layout generation](../perl/apply.pl#L49), [construction](../perl/core/wump_core.c#L533), [cleanup](../perl/core/wump_core.c#L426). |
| Wump task `next_binding`, `id`, `initialized`, `finished`, `main`, `critical` | Task-local lifecycle/region state. Task IDs are unique within a run, not a process-wide lifecycle trace. | [layout](../perl/apply.pl#L49), [spawn IDs](../perl/core/wump_core.c#L559), [checkpoint gate](../perl/core/wump_core.c#L27). |
| Wump task `numeric_active` | Task-owned short-lived pointer to an executor-owned numeric reader; valid only in the bounded non-scheduling numeric operation. | [numeric admission/release](../perl/core/wump_memory.c#L359), [protocol fixture](../tests/perl/numeric-admission.c). It must not become persistent state across executor migration. |
| `%ENV`, cwd, umask/credentials, signal disposition/pending counters, locale machinery, IO/PerlIO layers, extension `MY_CXT` and custom regex engines | Shared process/interpreter/native objects or unresolved; no generic per-act virtualization or affinity proof. | [unselected catalogue](state-inventory.tsv), [limited native audits](../perl/xs.pl), [native I/O restrictions](../perl/poll.pl). |

### Runtime and native state outside `intrpvar.h`

| State | Classification | Boundary |
| --- | --- | --- |
| `wump_g` stack mapping/SP, saved errno, slice clock, body/argument, cleanup/cancel hooks | Task-local | Fixed native stack, caller-owned referenced data, explicit hook ordering. [internal](../runtime/src/internal.h), [stack](../runtime/src/stack.c), [scheduler](../runtime/src/sched.c#L474). |
| `wump_worker` queues/cache/RNG and `wump_perl_allocator.numeric_reader` | Executor-local | Queue mutexes permit stealing; native call can donate a P to a different M. |
| `wump_machine`, `current` TLS, scheduler SP and marked-native-call state | Executor/native-thread-local, not act-local | Reload after switch; a machine can temporarily own no P. [scheduler](../runtime/src/sched.c#L11). |
| `Perl_wump_task_tls`, `Perl_wump_allocator_tls` | Native-thread-local selectors for task/executor-owned state | Interpreter identity filtering and dispatch hooks are required; their addresses cannot survive migration. |
| `wump_publisher`, `wump_metadata_depth`, native root-actor token | Native-thread-local protocol state | Valid only inside non-scheduling native regions; not persistent act storage. [publication](../perl/core/wump_publish.c), [memory](../perl/core/wump_memory.c). |
| `wump_perl_active`, run registry/channels/messages/groups/locks/panic | Process-global active bridge; intentionally shared per-run contents | One active Perl runtime. Registry mutex/atomics protect covered operations; separate C runtimes have a different contract. [bridge](../perl/core/wump_core.c#L195). |
| Perl run `allocators`, `nprocs`, `next_task`, `started`, `status` | Shared run container with distinct owners | Allocator array contains executor-owned pools; slot count is fixed after setup; task sequence is atomic; main entry/result fields are observed after runtime completion. |
| C `wump_runtime` queues, mapping registry, timer heap, machine/spare lists, stop/error and liveness counts | Intentionally shared within one C runtime | Native mutexes/atomics protect the covered protocols. Independent native runtimes do not imply independent simultaneous Perl bridges. [runtime structure](../runtime/src/sched.c#L34). |
| Task/channel/waitgroup/regex sequences | Intentionally shared IDs/counters | Atomic sequences, bounded lifetime/overflow handling; not a general observability stream. |
| Channel waiters, selection winner/timers, I/O waiters | Saved task-stack state plus intentionally shared queues | All queue references detach before stack release. [channel](../runtime/src/chan.c), [I/O](../runtime/src/io.c). |
| Callee-saved registers, MXCSR/x87 control, errno | Task-preserved subset of native context | Does not cover arbitrary C TLS, pthread affinity or full floating-point environment. [assembly](../runtime/src/ctx_x86_64.S). |

## Ranked risk register

Severity is impact if the boundary is violated, not an assertion that a defect
exists. Likelihood concerns supported use where evidence exists; **unknown**
means no rate was established. Confidence describes evidence for the stated
finding. No speculative entry below is a demonstrated memory-safety defect.

| Rank / ID | Finding and kind | Severity | Likelihood | Confidence | Evidence / consequence / next action |
| --- | --- | --- | --- | --- | --- |
| 1 / R1 | Unclosed interpreter-state inventory. **Coverage risk.** | High | Unknown | High that the gap exists | 234 unselected interpreter declarations remain unresolved; native statics/extension state add more. Review reachable access paths in small groups before claiming general parallel isolation. No count of defects is inferred. |
| 2 / R2 | Atomic lifetime/publication do not cover all mutable SV/aggregate/raw-native accesses. **Theoretical coverage risk.** | High | Unknown | High about bounded coverage; no new failing path demonstrated | [counter](../perl/refcount.pl), [access guards](../perl/core/wump_memory.c), [hidden roots](../tests/perl/hidden-roots.t). Direct flags/bodies, custom magic, weak-reference updates and opaque payloads need explicit access/edge contracts. |
| 3 / R3 | XS/compiler gates prevent ordinary dependency behavior in multi-slot mode. **Demonstrated compatibility limitation.** | High | High for affected APIs | High | Default JSON UTF-8 output fails at `utf8::encode`; runtime require/string eval/regex compilation and unaudited entries are deliberately rejected. Fix entry-specific contracts or keep them explicitly unsupported; do not admit whole modules to hide failures. |
| 4 / R4 | Blocking/affine native calls can stall a slot or shutdown. **Documented liveness limitation.** | High | Medium; application-dependent | High | Public C contract and [syscall tests](../tests/test_syscall.c). Handoff requires markers; arbitrary Perl I/O/XS is not automatically handed off. Do not promise asynchronous cancellation or transparent native affinity. |
| 5 / R5 | Cancellation/unwind coverage is not a full phase cross-product. **Coverage risk.** | High | Unknown | High about missing coverage | Normal callbacks and abandoned cleanup run under different rules. Existing tests cover selected locals, channels, compute shutdown and destructor callbacks; expand ordinary scope/exception/teardown combinations without changing expected Perl semantics. |
| 6 / R6 | Process/global/handle state is not generally act-isolated. **Documented boundary plus unresolved behavior.** | High | Medium for code using these facilities | Medium–high | Environment, signals, locale, stat/process state, IO layer caches and extension contexts are outside the 63-field selection guarantee. Define supported sharing/rejection policy and add safe differential cases; do not infer privacy from a task-local pointer. |
| 7 / R7 | Perl bridge embedding/reentry is narrower than C runtime reentry. **Unsupported configuration.** | High | Medium for embedders | High | [one active bridge](../perl/core/wump_core.c#L610); [sequential entry](../tests/perl/entry.c). Independent C runtimes pass tests; simultaneous independent Perl runtimes and arbitrary nested `perl_run` are not certified. |
| 8 / R8 | Arbitrary native TLS/stack/unwind affinity cannot migrate transparently. **Documented integration risk.** | High | Medium for unaudited XS/native libraries | High | Fixed mapped stacks preserve addresses, not pthread identity. Native mutex ownership, cached TLS and foreign nonlocal exits require separate contracts. Marked calls must return normally before exit/handoff. |
| 9 / R9 | Lifecycle/wait/cancellation correlation is incomplete. **Demonstrated diagnostics gap.** | Medium | High during failures | High | Panic includes actor ID; fixture probes expose context/slot identity. No public coherent trace of actor lifecycle, waiter/wakeup cause, migration and retirement was found. Add a bounded opt-in trace only after semantics are pinned. |
| 10 / R10 | Architecture prose mixes proposals with implemented restrictions. **Demonstrated documentation issue.** | Medium | Medium | High | Task `aTHX`, private parser, XS lock, general Perl I/O handoff, signal task and sysmon appear as design proposals. Current implementation differs. This audit and the design status note make those distinctions explicit. |
| 11 / R11 | Validation has important bounds. **Historical validation gap.** | High | Unknown | High | Full TSan is not green; whole-Perl MSan and Helgrind/DRD coverage remain blocked. Selected positive tests do not establish race freedom or CPAN compatibility. Keep failures visible and improve the relevant environment separately. |

Ordinary performance also remains an upstream acceptance blocker, as recorded
in the [core integration assessment](../DESIGN.md#core-scalar-access-and-ordinary-perl-acceptance-2026-10-31).
No new performance conclusion is drawn from this correctness audit.

## Compatibility matrix

Legend: **D** fresh same-version differential; **P** fresh project/native
fixture; **L** explicit limitation/rejection; **U** unresolved or not tested
here. A P entry is not an assertion of complete feature compatibility.

| Behavior | Fork, no Wump use | One main actor, 1 slot | Many cooperative actors, 1 slot | Multiple slots | Evidence / qualification |
| --- | --- | --- | --- | --- | --- |
| Nested arguments/lexicals, user `caller` frames, list/scalar/void context | D | D | D | D at 2/4 | New context fixture; first three user frames only. Separate P fixture proves actual parallel overlap. |
| Block eval, string exceptions, nested `local`, normal destruction | D | D | D | D at 2/4 | No shutdown/cancellation equivalence is inferred from normal completion. |
| `$_`, `$@`, captures, private-subject `pos()` | D | D | D | D at 2/4 | Shared-subject `pos()` and arbitrary concurrent regex engines are not certified. |
| Ordinary JSON::PP default UTF-8 output | D, including `WUMPPROCS=4` without import | P | Initial many-actor 1-slot run passed | L at 2/4 | `utf8::encode` is not admitted; gate applies even to one actor configured with multiple slots. Character output is separate. |
| Runtime string eval/require/do-file/dynamic regex compilation | Historical upstream evidence; not a fresh full stock sweep | P on covered paths | Partial P / U for general reentrant compile hooks | L | Block eval is supported separately. Parser/global compiler state is not fully task-local. |
| Scoped package/element locals, separator/hook caches, aliases | Historical ordinary tests plus P | P | P | P on covered paths | Typeglob/refalias/delete localization and unsupported magic remain L; no blanket `local` compatibility claim. |
| Shared scalar/aggregate accesses | Ordinary native behavior plus patched lifetime machinery | P | P | P for audited reads/writes/captures | Not every opcode, magic type, weak update, object cache or direct XS field access is audited. |
| Weak lifetimes / object destruction | Historical upstream plus P | P on selected lifetimes | P on selected lifetimes/callbacks | Partial P / U | No generic concurrent weak-reference mutation or arbitrary destructor/reentry guarantee. |
| XS | Ordinary mode permitted; historical upstream plus P | Permitted on one slot | U for arbitrary yielding/reentrant extensions | L unless individual entry admitted | Constant XS exception and typed argument restrictions remain. Permission on one slot does not establish arbitrary library reentrancy. |
| C netpoller/syscall handoff | C API outside actor restrictions apply | P | P | P | C runtime only; not transparent PerlIO, DBI or arbitrary XS integration. |
| Prepared Mojolicious application | Not a stock application differential | P | P for bounded jobs | P at 4 slots | CHECK-time preparation and specific native audits; not general CPAN/event-loop compatibility. |
| Main return, deadlock/panic, abandoned actors | Ordinary upstream exit differs intentionally | P | P | P on covered paths | Runtime-wide cooperative shutdown, no implicit child join or per-act cancel API. |
| Sequential embedded interpreter entry | P | P | P on covered callbacks | P for sequential runs | U for simultaneous independent Perl bridges and arbitrary reentrant `perl_run`. |
| Process environment, locale, native signal routing, shared IO cursor semantics | Historical ordinary behavior | Partial P / U | U / specific restrictions | U / specific restrictions | No implemented general per-act environment view or dedicated signal task. |
| Debug/custom runloops | Historical ordinary plus limited P | Limited P | Limited P | L | Parallel bridge rejects unsupported runloop/debug configurations. |

## Cancellation and suspension policy

Here cancellation means shutdown/abandonment of the runtime, not an implemented
per-act exception-injection API. Nested actor scopes are user scopes; actor
ancestry does not create an implicit join or independent cancellation domain.

| Point | Current permission / deferral | Evidence and limit |
| --- | --- | --- |
| Ordinary main-stack opcode boundary | Automatic polling every 256 ops; elapsed budget about 10 ms from first poll, or shutdown request | [runloop](../perl/active.pl), [checkpoint](../perl/core/wump_core.c#L27), [preempt tests](../tests/perl/preempt.t). |
| Nested ordinary Perl subs / block eval | Explicit yield allowed on covered paths; selected automatic checkpoints | New differential and existing tasks/parallel suites. No promise for arbitrary compiler/native callback state. |
| Parser activity, auxiliary callback stack, critical metadata/publication region | Automatic polling defers; guarded explicit scheduling is prohibited in metadata/publication regions | Full internal mutex callers still carry a no-scheduling contract. Do not confuse automatic deferral with universal explicit-yield prohibition. |
| Normal scope restoration / normal DESTROY | Supported yielding callbacks exist; automatic destructor preemption defers | `local.t`, `parallel.t`, `preempt.t`; cross-product throwing/reentrant cases remains incomplete. |
| Main-act INIT/END versus later global destruction | INIT/END run while the main act/scheduler are alive; covered END blocks can explicitly schedule. Later global destruction has no active actor runtime | Phase-order and scheduling cases in `entry.t`; do not classify all END work as abandoned-task teardown. |
| Channel/select/timer/I/O wait | Task parks; shutdown detaches all waiter references before registered cleanup | C runtime/select/I/O tests; these do not establish PerlIO integration. |
| Marked blocking native call | Continues on original OS thread/native stack; P donated. Shutdown waits for return | [C contract](../runtime/include/wump.h), `test_syscall`; no forced cancel or foreign longjmp out of callback. |
| Unmarked blocking native call / native CPU code with no checkpoints | Can occupy a P and delay shutdown indefinitely | Documented boundary; no unbounded hang experiment was introduced. |
| Abandoned Perl task cleanup | Correct act selected; finished/teardown state, unwind and temporaries cleanup on scheduler stack; old task body does not resume | [cleanup](../perl/core/wump_core.c#L426). Scheduling APIs require a live running task. Foreign cleanup behavior is not generalized. |
| Main return or uncaught actor panic | Runtime-wide stop; selected cleanup runs after waiters detach | Actor panic is not catchable by a different actor's surrounding eval; intentional semantics in `entry.t`. |

The C handoff API does not automatically establish a Perl API attachment or
allocator/reentry policy during a donated-slot native call. Current XS entry
dispatch does not transparently wrap every extension in that handoff. Native
library affinity, Perl callbacks and allocation during handoff require an
explicit separate contract before extending the supported surface.

## Missing regression tests and exact invariants

These are coverage requests, not claims that the invariant currently fails.
Do not turn a missing test into a public reproduction of a sensitive finding.

| Priority / ID | Small additional fixture | Invariant it must verify |
| --- | --- | --- |
| P0 / T1 | Bounded batches of unselected field families, beginning with compiler scratch, stat/IO selection and locale/read-only queries | Every reachable mutation has a stated owner and exclusion boundary; one actor cannot restore another actor's selected state. Reject unsupported use explicitly. No privileged/process-changing probe is required. |
| P0 / T2 | Forced migration inside nested user frames with an explicit progress/slot handshake | User-frame `caller`, wantarray, arguments, pad recursion, eval error and saved local state survive an **observed** executor change, not merely a configured slot count. The new differential does not force this. |
| P0 / T3 | Phase table for normal return, catchable exception and runtime shutdown from nested scopes | Each scope/temporary/guard is released once, enclosing locals are visible to cleanup, and cleanup ordering matches stock wherever semantics are unchanged. Shutdown does not resume abandoned bodies. |
| P0 / T4 | Bounded destructor callbacks that return, throw, reenter ordinary Perl or attempt scheduling, separately in normal cleanup and shutdown | Normal supported callbacks keep their behavior; teardown scheduling is rejected/deferred explicitly; one throwing destructor does not silently bypass required cleanup. Record exact supported boundaries before expanding them. |
| P1 / T5 | Application-level reference/aggregate operations spanning a yielding callback, exercised under existing sanitizer targets | Retain the extracted head/storage actually in use, not merely its old container; claims/pins return to baseline after success/error/abandonment. This expands existing tests rather than replacing them. |
| P1 / T6 | A small declared set of weak-reference/object/magic operations, including native API entry routes | Either the operation has a documented protected implementation and stock-equivalent semantics or is rejected before unsupported callback work. Atomic refcounts alone are not a passing criterion. |
| P1 / T7 | Native extension fixture with documented callback, TLS and normal-return contracts | After handoff, allocation uses the destination P; thread-affine native work stays pinned during its marked call; no pointer to executor-owned state is retained across yield. Deliberate misuse need not invoke undefined native behavior. |
| P1 / T8 | Prepared reactor cancellation/connection churn plus a second small event-loop stack | Bounded job admission, progress, correct responses, detached waits, clean shutdown and listener reuse hold with repeated starts. One passing Mojo workload is not a module-wide certificate. |
| P1 / T9 | Sequential multi-interpreter callback/reentry matrix and explicit rejection tests for unsupported nested entry | TLS selectors filter interpreter identity, root state returns correctly, and unsupported reentry fails without changing the already running interpreter. No simultaneous Perl-runtime support is presumed. |
| P2 / T10 | Legacy unused-mode fixtures for names/prototypes, hints, warning/exception hooks, IO selection and supported read-only locale queries | Installing the fork or setting WUMPPROCS alone does not activate actor semantics or gates. Compare identical source with stock; keep expected behavior unchanged. |
| P2 / T11 | Trace off/on comparison with bounded event loss and schedule-independent outputs | Opt-in observation changes diagnostics only, not returned values, gate decisions, cleanup counts or default hot-path behavior. |

## Prioritized implementation plan

1. **Keep the inventory executable.** Done in this pass: persist invariants,
   cover every pinned declaration, and fail the inventory check when task
   selection/layout declarations drift. Acceptance: six inventory checks and
   review of every reclassification; unresolved entries cannot silently become
   safe merely because a field was omitted.
2. **Extend differential context evidence before changing storage.** Start with
   T2 and T10 in isolated tests. Acceptance: unchanged stock observations in
   unused/one-actor/cooperative/parallel modes, with actual migration/overlap
   evidence supplied separately. Preserve existing hooks and callback semantics.
3. **Pin the shutdown/unwind phase contract.** Add T3/T4 as separate small
   fixtures, keeping cleanup behavior distinct from normal execution. Acceptance:
   exact-once cleanup, restored enclosing scope, no resumed abandoned bodies,
   and all existing runtime/Perl tests unchanged. Do not add a cancellation API.
4. **Close one access/XS boundary per change.** Choose a specific supported
   scalar/aggregate/native entry from T5–T7; document its roots, mutation
   protection, callback behavior and proof lifetime. Default JSON UTF-8 output
   is a concrete candidate for a separate entry audit, not justification for
   blanket admission. Acceptance: same-version differential, normal/error paths,
   targeted race/memory checks and ordinary performance protection.
5. **Resolve state families in bounded reviews.** Use T1 to classify a small
   compiler, handle/IO, locale or extension-context group. A milestone may end
   in an explicit supported/rejected boundary rather than a rewrite. Acceptance:
   catalogue evidence, a focused regression and no broadened safety claim.
6. **Add only diagnostics needed to explain failures.** Reuse existing context
   hooks and stable actor/channel IDs for an optional bounded event buffer:
   actor start/end, park/resume/cancel reason, execution slot and wait identity.
   Avoid blocking log output/native locks in switching-critical code. Acceptance:
   T11, explicit dropped-event counts and measured opt-in cost.
7. **Broaden integration and validation independently.** Run T8/T9 and the
   relevant upstream/sanitizer suites for changed paths. Fix tool/dependency
   environments separately; never suppress/skip failures to meet a milestone.
   Keep ordinary stock performance and Go primitive targets as distinct gates.

## Reproduction and maintenance

With the matching private and stock builds available:

```sh
make perl-state-inventory-test
make perl-context-compat-test STOCK_PERL=/absolute/path/to/stock/perl
```

The new inventory check is also in `perl-test`. The stock differential remains
an explicit target because a stock build is an additional dependency; it does
not silently substitute the private binary as its own control.

For this audit, existing verified build outputs were used with `make -o
perl-build ...` and an explicit BUILD/stock path. Fresh suite/native/runtime/
Mojo status manifests and the initial JSON transport failure are retained in
the audit checkpoint archive. No runtime source changed, so fresh performance
and full sanitizer/core rebuilds were not required and are not claimed.

Review this document and INVARIANTS.md when adding fields, callbacks, native
entries, escape paths, suspension points, or reclamation rules. Keep direct
evidence, documented rejection and unresolved behavior separate in future
updates. Selected test passes do not establish thread safety, general CPAN
compatibility or production readiness.
