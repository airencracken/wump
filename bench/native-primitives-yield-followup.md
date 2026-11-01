# Native yield regression follow-up

The first matched public-syntax matrix comparison **fails** its unchanged 10%
budget for four-slot yield: 660.1 to 738.5 ns/op, +11.87%. Its
[before](operation-matrix-native-baseline.json),
[after](operation-matrix-native-current.json) and
[complete check](operation-matrix-native-check.txt) remain recorded.

This follow-up interleaves the same two binaries through `api-overhead.pl yield
native 2000000`, rotating before/after order for seven runs on one/four slots.
CPU affinity remains `0,2,4,6`; benchmark source is clean `bc96e17`. Both binaries
compile native yield and verify all two million completions per sample.

| Slots | Before median, ns/op | After median, ns/op | Change | Before range | After range |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 189.631 | 189.836 | +0.108% | 187.346-191.787 | 186.888-192.620 |
| 4 | 662.819 | 708.305 | +6.863% | 642.998-683.056 | 694.995-764.803 |

| Slots | Before process median, ms | After process median, ms |
| ---: | ---: | ---: |
| 1 | 406.778 | 407.017 |
| 4 | 1353.048 | 1445.119 |

Four slots configure the scheduler around one yielding main act. These are
elapsed loop times, not four independently yielding actors or isolated ABI costs.
The larger fixture still measures a slowdown on four slots. Its different
work size and execution order cannot invalidate the original failure or prove
that it was noise. The default v3 baseline therefore remains the preceding
interpreter; no threshold, test expectation or scheduler code was changed to
make this checkpoint pass. The cause needs further investigation.

All 28 [raw samples](native-primitives-yield-followup.jsonl) and the
[machine record](native-primitives-yield-followup-machine.json) retain mode/order,
work/process times, both binary hashes/configurations, source hashes and the
exact capture runner. The binary identities match the full matrix pair.
Raw sample SHA256:
`d946f68b62122a11ba12b1ec926476152698c6cd1ce1a1cf4ed16b77a84272c3`.
