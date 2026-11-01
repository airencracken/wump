# Native channel method dispatch

Seven rotated runs on clean source `58e749c3dbf60085240ac86606dac58e92351e0d`, with CPU mask
`0,2,4,6` on AMD Ryzen 7 PRO 4750U with Radeon Graphics. Matching method-call loops on
one binary compare legacy wrappers, direct XS and the new core entries. Lower
is better; these include interpreter and scheduler work, not isolated ABI costs.

| Operation | Path | One slot, ns/exchange | Four slots, ns/exchange |
| --- | --- | ---: | ---: |
| buffered send/receive | Perl wrapper | 3936.3 | 4449.0 |
| buffered send/receive | Direct XS | 2743.2 | 3189.9 |
| buffered send/receive | Native core entry | 2698.4 | 3148.0 |
| request/reply rendezvous | Perl wrapper | 8830.6 | 31709.4 |
| request/reply rendezvous | Direct XS | 6246.8 | 20977.7 |
| request/reply rendezvous | Native core entry | 5976.1 | 20477.7 |

Median work-time reduction for native dispatch (negative means slower):

| Operation | Versus wrapper, 1 / 4 slots | Versus XS, 1 / 4 slots |
| --- | ---: | ---: |
| buffered send/receive | 31.4% / 29.2% | 1.6% / 1.3% |
| request/reply rendezvous | 32.3% / 35.4% | 4.3% / 2.4% |

Every path's range is retained to make scheduling variation visible:

| Operation/path | One-slot range, ns/exchange | Four-slot range, ns/exchange |
| --- | ---: | ---: |
| buffered send/receive/wrapper | 3872.1-3998.9 | 4410.6-4520.7 |
| buffered send/receive/xs | 2719.5-2749.3 | 3173.9-3217.5 |
| buffered send/receive/native | 2677.4-2715.4 | 3114.8-3169.7 |
| request/reply rendezvous/wrapper | 8657.2-8881.4 | 30616.2-32346.5 |
| request/reply rendezvous/xs | 6036.9-6342.6 | 20196.2-21220.7 |
| request/reply rendezvous/native | 5902.5-6037.4 | 19882.7-20578.7 |

Whole-process medians include interpreter/runtime startup, common dependencies
and report serialization:

| Operation/path | One slot, ms | Four slots, ms |
| --- | ---: | ---: |
| buffered send/receive/wrapper | 813.5 | 922.7 |
| buffered send/receive/xs | 574.8 | 664.9 |
| buffered send/receive/native | 565.6 | 655.5 |
| request/reply rendezvous/wrapper | 467.6 | 1613.7 |
| request/reply rendezvous/xs | 339.4 | 1076.2 |
| request/reply rendezvous/native | 325.6 | 1053.1 |

Buffered work runs 200,000 send/receive pairs through a capacity-one channel in
one main act. Rendezvous work runs 50,000 request/reply exchanges between two
acts, using two unbuffered channels and a verified worker-completion message.
Four slots describe scheduler configuration, not four independent worker pairs.
The worker is enqueued before timing; its first entry may still occur afterward.
Channel construction and final closes are outside work timing.

All paths use ID-backed channel proxies, one-level subclasses of Wump::Channel,
and the same method-lookup syntax, keeping inheritance work in each path.
The wrapper class reproduces the previous Perl method bodies; the XS class
aliases the original compatibility entries; the native class uses the original
core methods. Native mode verifies the actual method bindings. Every reply,
total count and checksum is checked. Clock constants are prepared before timing;
ASCII JSON preserves existing parallel XS restrictions. Modes rotate each run.

All 84 [raw samples](native-channel-api.jsonl), process timings, mode order,
binary/source hashes, compiler settings and exact capture runner are retained
in the [machine record](native-channel-machine.json). The
[public matrix](operation-matrix-channel-current.md) separately measures task
completion and channel ping-pong against stock Perl, forks, ithreads and Go.

The core dispatch removes wrapper/pad setup and XS invocation, while preserving
normal method resolution. Payload copies, publication, registry lookup,
synchronization and interpreter loops remain. These host-specific results do
not establish general application speed or Go parity.

Raw sample SHA256: `8d336f04b721d9dfd7f3972ad98f46ced426f02f311cb2ff9eea5aaa5049e661`.

The earlier builds retain their own 84-sample captures and machine records:
[initial samples](native-channel-api-initial.jsonl),
[initial machine](native-channel-machine-initial.json),
[numeric-refinement samples](native-channel-api-arithmetic.jsonl) and
[numeric-refinement machine](native-channel-machine-arithmetic.json).
Their binary identities differ; these datasets are not pooled with the final capture.
