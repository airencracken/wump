# Native task, channel and timer dispatch

Seven rotated runs on clean source `bc96e1772b9b9d292ec7f24f4aaae4e4523d3f41`, with CPU mask
`0,2,4,6` on AMD Ryzen 7 PRO 4750U with Radeon Graphics. Matching loops on one binary
compare the qualified wrapper, direct XS and imported native operation. Lower
is better; these include interpreter and scheduler work, not isolated ABI costs.

The separate full-matrix regression check fails four-slot yield (+11.87%). A
[larger old/new follow-up](native-primitives-yield-followup.md) measures +6.86%;
the original failure remains recorded and the default baseline is unchanged
from the preceding interpreter. Same-binary dispatch gains below do not resolve it.

| Operation | Path | One slot, ns/op | Four slots, ns/op |
| --- | --- | ---: | ---: |
| yield | Perl wrapper | 606.7 | 3439.9 |
| yield | Direct XS | 314.9 | 1356.1 |
| yield | Native core operation | 187.7 | 691.5 |
| spawn/completion | Perl wrapper | 18822.7 | 19692.9 |
| spawn/completion | Direct XS | 18264.7 | 18111.0 |
| spawn/completion | Native core operation | 18089.3 | 17100.5 |
| channel create/close | Perl wrapper | 2394.1 | 2936.4 |
| channel create/close | Direct XS | 1739.5 | 2225.0 |
| channel create/close | Native core operation | 1601.2 | 1999.6 |
| sleep(0) | Perl wrapper | 859.4 | 4255.4 |
| sleep(0) | Direct XS | 373.8 | 1535.8 |
| sleep(0) | Native core operation | 234.5 | 863.8 |

Median work-time reduction for native dispatch (negative means slower):

| Operation | Versus wrapper, 1 / 4 slots | Versus XS, 1 / 4 slots |
| --- | ---: | ---: |
| yield | 69.1% / 79.9% | 40.4% / 49.0% |
| spawn/completion | 3.9% / 13.2% | 1.0% / 5.6% |
| channel create/close | 33.1% / 31.9% | 8.0% / 10.1% |
| sleep(0) | 72.7% / 79.7% | 37.3% / 43.8% |

Every path's range is retained to make scheduling variation visible:

| Operation/path | One-slot range, ns/op | Four-slot range, ns/op |
| --- | ---: | ---: |
| yield/public | 595.5-618.8 | 3291.8-3478.0 |
| yield/xs | 312.4-319.0 | 1269.7-1370.4 |
| yield/native | 186.5-189.0 | 653.4-717.3 |
| spawn/completion/public | 18746.1-19041.5 | 19276.5-20526.4 |
| spawn/completion/xs | 18173.4-18667.8 | 17667.7-18472.7 |
| spawn/completion/native | 18047.2-18625.7 | 16749.0-17826.9 |
| channel create/close/public | 2378.8-2430.7 | 2871.3-3006.9 |
| channel create/close/xs | 1729.8-1748.6 | 2189.5-2252.2 |
| channel create/close/native | 1588.5-1615.7 | 1946.9-2036.0 |
| sleep(0)/public | 850.0-868.9 | 3838.5-4282.8 |
| sleep(0)/xs | 364.2-380.3 | 1468.9-1564.2 |
| sleep(0)/native | 230.1-239.0 | 786.9-875.0 |

Whole-process medians include interpreter/runtime startup, common dependencies
and report serialization:

| Operation/path | One slot, ms | Four slots, ms |
| --- | ---: | ---: |
| yield/public | 148.2 | 715.9 |
| yield/xs | 89.9 | 298.6 |
| yield/native | 64.7 | 167.0 |
| spawn/completion/public | 409.8 | 431.0 |
| spawn/completion/xs | 398.7 | 398.0 |
| spawn/completion/native | 397.5 | 379.4 |
| channel create/close/public | 51.8 | 56.6 |
| channel create/close/xs | 43.6 | 50.5 |
| channel create/close/native | 44.5 | 48.4 |
| sleep(0)/public | 198.5 | 876.7 |
| sleep(0)/xs | 101.5 | 335.2 |
| sleep(0)/native | 74.7 | 201.1 |

Yield and zero sleep run 200,000 iterations in one main act. Four slots describe
the scheduler configuration, not four independently yielding actors. Spawn
runs 20,000 tasks in cohorts of at most 1,024; every task sends one completion
value through the same channel methods in all three modes. Channel creation
runs 10,000 buffered constructors with the same close method in every mode.
Closed channels retain their registry entries until runtime teardown; this is
a bounded creation/close probe, not an RSS or reclamation benchmark.

Each sample verifies the total count; spawn also checks every reply. Native
mode checks the compiled optree, so missing intrinsic lowering cannot silently
produce a function timing under a native label. Clock constants are prepared before
timing; ASCII JSON reporting preserves the existing parallel XS restrictions.
Modes rotate within each run. These samples are a same-binary dispatch
experiment; the separate matrix uses unique task IDs and different work.

All 168 [raw samples](native-primitives-api.jsonl), process timings, mode order,
binary/source hashes, compiler settings and exact capture runner are retained
in the [machine record](native-primitives-machine.json). The
[public-syntax matrix](operation-matrix-native-current.md) compares the preceding
and new interpreter with stock Perl, forks, ithreads and Go controls.

Native dispatch removes call-frame overhead; it does not remove task snapshots,
publication, channel methods, synchronization or interpreter cleanup. These
host-specific results do not establish general application speed or Go parity.

Raw sample SHA256: `c340869a85c342fe6600dd876e04835c15507a41168cefdee307e9c215b9d6bb`.
