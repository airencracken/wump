# Perl compatibility and open boundaries

Wump is a parallel preview for pinned Perl 5.42.2 on Linux x86-64. Acts share
one interpreter and compiled code; acts are not ithread clones. Supported
paths select act execution storage while executor allocation/cache state
follows the destination slot. The [invariants](INVARIANTS.md) describe those
protocols; the [validation reference](VALIDATION.md) records tested scope.

## Execution modes

| Mode | Current contract |
| --- | --- |
| No Wump import | Ordinary Perl behavior; checked against matched stock separately from active execution |
| One execution slot | Cooperative acts with separate supported execution state; this does not prove parallel safety |
| Multiple execution slots | Audited Perl operations and explicitly admitted native entries; unsupported compiler/XS paths fail explicitly |
| Embedded interpreters | Inactive/different interpreter selection, sequential entries and clone initialization have native fixtures; arbitrary concurrent embedding remains unaudited |

`WUMPPROCS` defaults to one and accepts 1–256 slots. Most project regressions
exercise one/four slots, with selected scaling and synchronization checks on
additional counts. A rendezvous verifies actual simultaneous execution and
one interpreter; setting an environment variable alone is not parallel proof.

## Supported module paths

UTF-8 encode/decode operate under the audited native entry protocol.
JSON::PP localizes invocation scratch state, including its encoder/parser
fields, so nested calls and suspension restore the caller's values. Prepared
default codecs avoid first-use mutation during parallel execution. Carp and
caller paths route supported scratch arrays and native cache heads through
act storage. Tests cover reentrancy, warning/exception callbacks, yields,
namespace metadata, publication, alias precedence and scope restoration.

These are entry-specific guarantees. A module being installed, loaded, or
passing a selected fixture does not admit arbitrary XS code. Foreign native
code may retain interpreter fields, native TLS, mutable caches or thread-affine
resources that the scheduler cannot safely move. Runtime loading, native
callbacks and automatic blocking-call handoff need separate audits.

The [Mojolicious fixture](../examples/mojo/README.md) prepares its dependency
stack before parallel work and tests bounded HTTP/WebSocket jobs on one/four
slots. Its in-process Test2-based job/service harness runs on one slot. Loading
Test2 dynamically inside active multi-slot work reaches an INIT-phase string
eval rejected by the compiler gate. That restriction remains open; relaxing
the gate without protecting shared compiler state would be incorrect.

## Execution-state inventory

The [catalogue](state-inventory.tsv) includes 344 interpreter declarations,
57 process declarations and eight Wump interpreter fields: 409 rows, including
conditional fields not compiled on this host. Current classifications are
63 task-local, seven executor-local, 24 intentionally shared, 82 interpreter-global
and 233 unresolved declarations. These counts measure reviewed classification,
not defects or a percentage of compatibility achieved.

A private field can point to a shared value. Native C statics, external TLS,
opaque extension payloads and callback-retained addresses need separate
inventories. Regenerating the catalogue verifies coverage, not concurrency
safety. New state must identify ownership, access, callback and teardown rules.

## Remaining work

| Boundary | Current limitation / next requirement |
| --- | --- |
| Generic shared values | Complete magic, weak-reference, object/cache and mutable aggregate coverage; preserve lifetime during callbacks and retirement |
| Arbitrary XS | Audit each entry's state, TLS, callbacks, blocking behavior and affinity; keep unaudited parallel calls rejected |
| Compiler and namespaces | Coordinate runtime string eval, require, phase callbacks and code/namespace mutation with running and suspended acts |
| Perl I/O | Integrate automatic poller/blocking handoff; explicit C epoll and handoff APIs do not cover every Perl handle |
| Process state | Define broader signal, locale, environment and fork behavior; ordinary-mode differentials do not establish parallel safety |
| Embedding and native affinity | Specify which callbacks/destructors may migrate and how foreign state is attached and reclaimed |
| Whole-project race tooling | Resolve the separate upstream ithreads clone race exposed by full TSan; scoped Wump passes do not close it |
| Performance | Reduce private-path and shared metadata overhead while preserving stock behavior and observable failure paths |
| Deployment | Implement static application/XS packaging, dependency locking/cache and the build tool; add portability beyond Linux x86-64 |

Cancellation is cooperative: done channels and structured cleanup can stop
work at explicit waits/checkpoints. There is no general asynchronous individual
act kill. Abandonment cleanup currently ends the entire run and must cancel
native waiters before releasing Perl frames or selection storage. Destructor
callbacks and native affinity remain part of that contract.

Priorities are protecting these semantics while making private operations
cheaper, expanding audited native/module paths, coordinating compilation and
I/O, and building deployable application bundles. Keep General Perl, Wump and
Perl-for-Wump changes in their [separate lanes](BENCHMARKS.md#three-optimization-lanes).
Historical audits and obsolete failures remain in Git; current restrictions
and unresolved failures stay visible here and in validation.
